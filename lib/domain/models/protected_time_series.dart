import 'dart:collection';

import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';

/// 一条**自定义保护时间系列**（课程与保护时间管理修复计划 Task 6）。
///
/// ## 为什么必须按"系列"而不是"发生次数"来读
///
/// 管理页此前读的是"未来 180 天的展开结果"，于是
///
/// - 一条"每周二健身"会按发生次数出现 **26 行**（用户以为建了 26 条）；
/// - 180 天之外的系列**根本读不到**（用户建了却看不见，于是又建一条重复的）；
/// - 改名时不知道改的是哪一条——每一行看起来都是同名的独立事项。
///
/// 计划 §3 明确禁止从展开结果反推系列。这个模型是**锚点行的直接读模型**：
/// 一行 = 一个 `calendar_events` 锚点 = 一条用户建的系列。
///
/// ## 规则来源的保护时间不在这里
///
/// 睡眠／早餐／午餐／晚餐／固定休息来自 `PlanningRules.protectedTimes`，
/// **没有 `CalendarEvent` 锚点**（计划 §2.3 末段）。它们属于设置页，
/// 混进这份清单只会让用户以为可以直接删掉早上的保护。
final class ProtectedTimeSeries {
  ProtectedTimeSeries({
    required this.anchorId,
    required this.title,
    required this.timeZoneId,
    required this.startMinute,
    required this.endMinute,
    required DateTime validFromLocalDate,
    this.validUntilLocalDate,
    Set<int> weekdays = const {},
    this.intervalWeeks = 1,
    this.dayKind = DayKind.any,
    this.notes = '',
    required this.updatedAtUtc,
  }) : validFromLocalDate = _dateOnly(validFromLocalDate),
       weekdays = UnmodifiableSetView(Set.of(weekdays)),
       _exceptions = const [];

  final EntityId anchorId;
  final String title;

  /// 事项自己的时区（规范 §4.1：换算只在入口做一次）。
  final String timeZoneId;

  /// 本地起止分钟。**跨午夜时 `endMinute < startMinute`**，与 `LocalTimeRange` 同约定。
  final int startMinute;
  final int endMinute;

  /// 空集合 = **单次**（没有重复规则）。非空 = 每周／单双周。
  final Set<int> weekdays;

  final int intervalWeeks;
  final DayKind dayKind;
  final String notes;

  final DateTime validFromLocalDate;
  final DateTime? validUntilLocalDate;

  /// 锚点行的 `updated_at_utc`，供保存时发现**过期页面**（乐观并发）。
  final DateTime updatedAtUtc;

  List<DateTime> _exceptions;

  /// 这条系列名下的**逐次例外**日期（本地日期）。
  ///
  /// 管理页要告诉用户"改整个系列会影响 N 次、其中有 M 次是你单独调过的"，
  /// 而"单独调过"这件事只有例外行能回答。
  List<DateTime> get exceptionDates => UnmodifiableListView(_exceptions);

  /// 由读模型装配时填入例外日期（内部使用）。
  set exceptionDates(List<DateTime> value) => _exceptions = List.of(value);

  bool get repeats => weekdays.isNotEmpty;

  LocalTimeRange get range =>
      LocalTimeRange(startMinute: startMinute, endMinute: endMinute);

  /// 默认显示用的整点区间文本（跨午夜时两端顺序按真实时间）。
  int get durationMinutes => endMinute > startMinute
      ? endMinute - startMinute
      : LocalTimeRange.minutesPerDay - startMinute + endMinute;

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}

/// 一条系列**会怎么变**（计划 Task 6 Step 1：范围语义）。
///
/// 三种操作的对象不同，混成一种会出现"以为只改这一次，结果整条都变了"：
/// - [singleOccurrence]：只改一次（写一行例外）；单次系列退化为整条；
/// - [followingOccurrences]：从某次起改（拆分规则）；
/// - [entireSeries]：改整条锚点与它的规则。
///
/// **`singleOccurrence` 只在"从日历上的某一次进入"时可用**：没有真实发生时间
/// 就没有"这一次"可言，而管理页上的一行是整个系列。
enum ProtectedTimeEditScope {
  singleOccurrence,
  followingOccurrences,
  entireSeries,
}

/// 从"管理页那一行"（整个系列）出发时，允许的范围只有整条。
const List<ProtectedTimeEditScope> scopesFromSeriesList = [
  ProtectedTimeEditScope.entireSeries,
];

/// 从"日历上的某一次"出发时，三种范围都可用。
const List<ProtectedTimeEditScope> scopesFromOccurrence = [
  ProtectedTimeEditScope.singleOccurrence,
  ProtectedTimeEditScope.followingOccurrences,
  ProtectedTimeEditScope.entireSeries,
];
