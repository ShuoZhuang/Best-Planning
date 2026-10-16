import 'dart:collection';

import 'package:personal_planner/domain/models/time_range.dart';

/// 一次改写的作用范围（计划 §2.2 的三选一）。
///
/// **它原来定义在 `application/calendar_service.dart` 里**，本轮移到领域层：
/// [CalendarEditTarget] 是领域模型、必须带上范围，而领域模型不该反向 import 应用层。
///
/// **迁移方式是"移 + 转发"而不是"复制"**：`calendar_service.dart` 现在 `export` 这里
/// 的定义，因此既有 `import '.../calendar_service.dart'` 的调用点一个字都不用改，
/// 也不会出现两个同名枚举各管一半。
enum EventEditScope { singleOccurrence, followingOccurrences, entireSeries }

/// 一个字段的**改写意图**（计划 §2.0.1）。
///
/// **为什么不能是裸的 `String`**：日视图的改写对话框只能看到标题、备注与时间——
/// 地点是它**根本没有展示**的字段。用裸字符串表示时，"我没编辑这一项"只能被写成
/// `''`，而 `''` 同时又是"用户明确清空地点"的意思。两者在写入端无法区分，于是
/// 用户只改一次钟点，`教一 302` 就被写成空串（计划 §1.1／C04 的实际事故）。
///
/// 这个类型把两种意图在**类型层面**分开：
///
/// - `null` 或 [KeepField]：当前界面没有编辑这一项，仓储必须在事务内保留锚点原值；
/// - [SetField]：用户明确提交了这个值；`SetField('')` 就是"清空"。
sealed class FieldPatch<T> {
  const FieldPatch();
}

/// "保持锚点原值"。[FieldPatch] 为 `null` 时语义完全相同。
final class KeepField<T> extends FieldPatch<T> {
  const KeepField();
}

/// "写这个值"。
final class SetField<T> extends FieldPatch<T> {
  const SetField(this.value);

  final T value;
}

/// 把"保持／设置"解析成要落库的最终值。
///
/// [current] 是**同一事务内**重新读到的权威值。把它作为必填参数是刻意的：
/// 调用点必须回答"原值从哪来"，而不是用一个局部默认值糊过去。
extension FieldPatchResolution<T extends Object> on FieldPatch<T>? {
  T resolve(T current) => switch (this) {
    null => current,
    KeepField<T>() => current,
    SetField<T>(:final value) => value,
  };
}

/// 一次日历改写的**显式 patch**（计划 §2.0.1，取代此前的"完整草稿"）。
///
/// **它是 patch 而不是草稿**：只装"用户这一次真的改了什么"。没有出现在这个对象里的
/// 字段——`areaId`、`projectId`、`kind`、`sourceKind`、`importBatchId`、
/// `logicalCourseId`、事项时区与规则时区——一律由仓储在事务内从锚点读取后保留。
///
/// **因此这里没有 `timeZoneId`**：此前草稿带时区，而旧包装器在缓存里找不到这条事项时
/// 只能写 `UTC` 兜底，于是"事件时区与重复规则时区不一致"（计划 §1.1／C03）。
/// 时区的权威来源只有一个：规则行（有规则时）或锚点行自身。
///
/// **也没有 `kind`**：把一条保护时间改写成固定日程会让"排程硬禁区"凭空消失，
/// 而用户以为自己只是改了时间。类别只能由锚点决定。
///
/// **不可变**：构造后字段不可再改，因此"校验通过"与"实际写入"看到的是同一份数据。
final class CalendarEventPatch {
  CalendarEventPatch({
    required String title,
    this.notes = '',
    required this.startAtUtc,
    required this.endAtUtc,
    this.location,
  }) : title = title.trim(),
       _errors = _validate(
         title: title.trim(),
         startAtUtc: startAtUtc,
         endAtUtc: endAtUtc,
       );

  final String title;
  final DateTime startAtUtc;
  final DateTime endAtUtc;

  /// 备注。课表导入把**教师名**写在这一列里，因此它常常不是空的。
  ///
  /// 日视图与保护时间编辑器都展示并提交它，因此这里用普通字符串：
  /// 能看到它就意味着"用户提交的就是完整值"。
  final String notes;

  /// 地点。`null`／[KeepField] 表示当前界面没有展示这一项，必须保留锚点原值；
  /// [SetField] `''` 才是"用户明确清空地点"。
  final FieldPatch<String>? location;

  final Map<String, String> _errors;

  /// 字段级错误（空表示合法）。键与界面上的字段一一对应。
  Map<String, String> get fieldErrors => UnmodifiableMapView(_errors);

  bool get isValid => _errors.isEmpty;

  TimeRange get range => TimeRange(startUtc: startAtUtc, endUtc: endAtUtc);

  static Map<String, String> _validate({
    required String title,
    required DateTime startAtUtc,
    required DateTime endAtUtc,
  }) {
    final errors = <String, String>{};
    if (title.isEmpty) errors['title'] = '标题不能为空';
    // **必须是 UTC**：全仓库的持久化时刻都是 UTC（规范 §4.1），
    // 放一个本地时刻进去会在别的时区表现为"差了几小时"，而不报错。
    if (!startAtUtc.isUtc) errors['startAtUtc'] = '开始时刻必须是 UTC';
    if (!endAtUtc.isUtc) errors['endAtUtc'] = '结束时刻必须是 UTC';
    if (startAtUtc.isUtc && endAtUtc.isUtc && !endAtUtc.isAfter(startAtUtc)) {
      errors['endAtUtc'] = '结束时间必须晚于开始时间';
    }
    return errors;
  }
}

/// 锚点在写事务里**已不存在**（计划 Task 2 Step 3）。
///
/// 只在调用方给了 [CalendarEditTarget.expectedUpdatedAtUtc]（＝它在页面上确实读到过
/// 这一条）时抛出：没有期望值时的"删不到"仍按下述幂等约定处理。
final class CalendarEditMissingException implements Exception {
  const CalendarEditMissingException();
}

/// 锚点在同一事务内被读出来时，修订号与页面读到的**不一致**（乐观并发）。
///
/// **零写入**：这个异常在写任何一行之前抛出，因此"别处已经改过"不会被覆盖。
final class CalendarEditStaleException implements Exception {
  const CalendarEditStaleException();
}

/// 重复规则的草稿（与 [CalendarEventEditDraft] 配套）。
///
/// **为什么与事件草稿分开**：单次日程没有规则，"改这一次"也**不允许**改规则
/// （改了就等于改了整个系列）。分成两个参数之后，"这次改写能不能动规则"
/// 在调用点就看得见。
final class RecurrenceEditDraft {
  RecurrenceEditDraft({
    required Set<int> weekdays,
    this.intervalWeeks = 1,
    required this.validFromLocalDate,
    this.validUntilLocalDate,
  }) : weekdays = UnmodifiableSetView(Set.of(weekdays)),
       _errors = _validate(
         weekdays: weekdays,
         intervalWeeks: intervalWeeks,
         validFromLocalDate: validFromLocalDate,
         validUntilLocalDate: validUntilLocalDate,
       );

  final Set<int> weekdays;
  final int intervalWeeks;
  final DateTime validFromLocalDate;
  final DateTime? validUntilLocalDate;

  final Map<String, String> _errors;

  Map<String, String> get fieldErrors => UnmodifiableMapView(_errors);
  bool get isValid => _errors.isEmpty;

  static Map<String, String> _validate({
    required Set<int> weekdays,
    required int intervalWeeks,
    required DateTime validFromLocalDate,
    required DateTime? validUntilLocalDate,
  }) {
    final errors = <String, String>{};
    if (weekdays.isEmpty) {
      errors['weekdays'] = '至少要选一个星期';
    }
    if (weekdays.any((day) => day < DateTime.monday || day > DateTime.sunday)) {
      // `DateTime.monday`…`DateTime.sunday` 是 1…7；越界的值会让
      // "这一天该不该展开"永远为假，于是规则看起来存在却一次都不发生。
      errors['weekdays'] = '星期取值必须在周一到周日之间';
    }
    if (intervalWeeks < 1 || intervalWeeks > 52) {
      // 52 是上限：再大就等于"一年最多一次"，那应该用一次性事项表达，
      // 而不是一条几乎不发生的规则（它还会让展开器白跑）。
      errors['intervalWeeks'] = '间隔周数必须在 1 到 52 之间';
    }
    final until = validUntilLocalDate;
    if (until != null && until.isBefore(validFromLocalDate)) {
      errors['validUntilLocalDate'] = '结束日期不能早于开始日期';
    }
    return errors;
  }
}

/// 一次改写的**目标**：改哪一条、改哪一次、以什么范围改（计划 Task 2 Interfaces）。
///
/// [occurrenceStartUtc] 是可空的，而这一点是有意的：
/// "整个系列"不需要它（改的是锚点与规则），而"这一次／此次及以后"
/// **必须**有它——没有它就无法表达"从哪一次开始"。
/// 缺它的那两种范围由服务层返回 `invalid`，而不是猜一个日期出来。
final class CalendarEditTarget {
  const CalendarEditTarget({
    required this.anchorId,
    required this.scope,
    this.occurrenceStartUtc,
    this.expectedUpdatedAtUtc,
  });

  final String anchorId;
  final EventEditScope scope;
  final DateTime? occurrenceStartUtc;

  /// 打开编辑页时读到的 `updated_at_utc`。非空时用于**乐观并发**：
  /// 保存前若数据库里的值已经变了，说明别处改过这条事项，返回 `stale` 而不是覆盖。
  final DateTime? expectedUpdatedAtUtc;
}

/// 一次日历改写的**结果**（计划 Task 2 Interfaces，与计划 §5 的失败表一一对应）。
///
/// **为什么不是 `bool`**：`CalendarService` 的改写方法此前返回 `bool`，
/// 于是"过期"与"端口没装配"与"事务失败"在界面上不可区分，只能给一句笼统的
/// "保存失败"。计划 §5 要求这三种情况给**不同的**用户可见文案与不同的数据结果。
enum CalendarMutationStatus {
  /// 写入成功。
  saved,

  /// **已经落库**，但提交后的重排原因回调抛了错。
  ///
  /// 与 [failed] 分开的理由：把已经保存的改动报告成"保存失败"会让用户
  /// 再改一次，而那会写入第二遍。
  savedWithWarning,

  /// 目标已不存在。
  missing,

  /// 页面数据过期（别处已改）。
  stale,

  /// 草稿本身不合法。
  invalid,

  /// 端口未装配。
  unsupported,

  /// 写入过程抛了异常（事务已回滚）。
  failed,
}

final class CalendarMutationResult {
  const CalendarMutationResult._(this.status, this.error, this.fieldErrors);

  factory CalendarMutationResult.saved() =>
      const CalendarMutationResult._(CalendarMutationStatus.saved, null, null);

  /// 数据已落库（[status] 仍是 `savedWithWarning`），但需要如实告诉用户
  /// "内容已保存，但变更记录失败"。
  factory CalendarMutationResult.savedWithWarning(String message) =>
      CalendarMutationResult._(
        CalendarMutationStatus.savedWithWarning,
        message,
        null,
      );

  factory CalendarMutationResult.failed(
    CalendarMutationStatus status,
    String error,
  ) => CalendarMutationResult._(status, error, null);

  factory CalendarMutationResult.invalid(Map<String, String> fieldErrors) =>
      CalendarMutationResult._(
        CalendarMutationStatus.invalid,
        null,
        UnmodifiableMapView(Map.of(fieldErrors)),
      );

  final CalendarMutationStatus status;

  /// 用户可读的一句话（已含事项标题与下一步），不是异常 toString。
  final String? error;

  /// 字段级错误（仅在 [CalendarMutationStatus.invalid] 时有值）。
  final Map<String, String>? fieldErrors;

  bool get isSuccess => status == CalendarMutationStatus.saved;
  bool get wasPersisted =>
      status == CalendarMutationStatus.saved ||
      status == CalendarMutationStatus.savedWithWarning;
}
