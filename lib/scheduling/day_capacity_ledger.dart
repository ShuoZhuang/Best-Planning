import 'dart:collection';

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_eligibility.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// **某个本地日**的容量账本快照（算法 17，计划 §2 术语表 / §6）。
///
/// ## 为什么必须把四个口径分开
///
/// 算法 16 只有"空闲分钟"一个数字，于是三件不同的事被压成同一句话：
///
/// | 用户的观察 | 真实含义 |
/// | --- | --- |
/// | "日历上明明空着" | **视觉空白** [calendarGapMinutes] |
/// | "可是排不进去" | **合规容量**（截止／星期／片段过滤之后） |
/// | "引擎说容量不足" | **许可容量**耗尽 [licensedCapacityMinutes] |
///
/// 计划 §2 因此把口径固定成四个量，并规定 **"有缺口"不等于"可用时间不足"**：
/// 只有许可容量真的小于剩余量时才允许使用容量不足文案（§Global Constraints）。
///
/// ## 为什么"许可容量"是 `min(硬空闲, 每日上限)`
///
/// 每日可移动上限的语义是"这一天最终安排的可移动任务总时长不超过 N"（它是**结果**
/// 约束，不是可见性约束——1.7.1 已经为此把"按上限截断候选"删掉）。
/// 把它与硬空闲取最小值，才得到"这一天最多能承接多少任务分钟"这个对用户有意义的数。
///
/// ## `remainingMinutes` 为什么是两个上限的最小值
///
/// ```text
/// remainingMinutes =
///   min(max(0, calendarGap − allocated),
///       max(0, licensed − used − allocated))
/// ```
///
/// 两个上限分别挡住两件不同的事：
/// - **视觉空白**：候选只能放在真实空闲里（否则会与基线块重叠）；
/// - **许可容量**：可移动任务总量不得超限。
///
/// 只取一个都会漏：只取空白会超过每日上限；只取许可会把"这天已经有别的块的时段"
/// 当成可用。
final class DayCapacitySnapshot {
  const DayCapacitySnapshot({
    required this.localDate,
    required this.hardFreeMinutes,
    required this.calendarGapMinutes,
    required this.licensedCapacityMinutes,
    required this.usedMovableMinutes,
    required this.allocatedMinutes,
    required this.remainingMinutes,
    required this.utilizationPermille,
    this.overLicensedMinutes = 0,
  });

  /// 归一后的本地日期（时间部分为 0）。
  final DateTime localDate;

  /// **日硬空闲**：只扣固定、保护、睡眠与课程过渡，不扣任何任务块（计划 §2）。
  final int hardFreeMinutes;

  /// **视觉空白**：日硬空闲再扣掉基线里占住时间的任务块（计划 §2）。
  final int calendarGapMinutes;

  /// **日许可容量** = `min(hardFreeMinutes, 当日可移动上限)`，不小于 0（计划 §2）。
  final int licensedCapacityMinutes;

  /// **日已用量**：基线里当日所有计入可移动上限的任务块分钟，**包含锁定/钉住的块**，
  /// 不含固定与保护日程（计划 §2）。
  final int usedMovableMinutes;

  /// 本轮跨日分配已经许诺给这一天的分钟。
  final int allocatedMinutes;

  /// 见类型文档的公式。恒不小于 0。
  final int remainingMinutes;

  /// **日负载率**（千分比）：`ceil((used + allocated) * 1000 / licensed)`。
  ///
  /// - 许可容量为 0 且分子为 0 ⇒ 记 0，并禁止分配；
  /// - 许可容量为 0 而分子大于 0 ⇒ 记 1001，并产生结构异常。
  ///
  /// **不除零**：这是计划 §2 的硬要求，也是"某天没有容量"与"某天算错了"必须能区分的原因。
  final int utilizationPermille;

  /// 基线已经使 `used > licensed` 时超出的分钟数（0 表示正常）。
  ///
  /// **刻意不把负数夹成 0 之后继续声称输入正常**（计划 Task 3 Step 3）：一个"已用
  /// 超过上限"的基线本身就是要报告的结构异常，夹掉它只会让缺口无法解释。
  final int overLicensedMinutes;

  /// 是否检测到"基线已用超过许可容量"这一结构异常。
  bool get hasBaselineOverflow => overLicensedMinutes > 0;

  /// 这一天是否还能承接任何分钟。
  bool get canAllocate => remainingMinutes > 0;

  DayCapacitySnapshot copyWith({
    int? allocatedMinutes,
    int? remainingMinutes,
    int? utilizationPermille,
  }) => DayCapacitySnapshot(
    localDate: localDate,
    hardFreeMinutes: hardFreeMinutes,
    calendarGapMinutes: calendarGapMinutes,
    licensedCapacityMinutes: licensedCapacityMinutes,
    usedMovableMinutes: usedMovableMinutes,
    allocatedMinutes: allocatedMinutes ?? this.allocatedMinutes,
    remainingMinutes: remainingMinutes ?? this.remainingMinutes,
    utilizationPermille: utilizationPermille ?? this.utilizationPermille,
    overLicensedMinutes: overLicensedMinutes,
  );

  @override
  bool operator ==(Object other) =>
      other is DayCapacitySnapshot &&
      other.localDate == localDate &&
      other.hardFreeMinutes == hardFreeMinutes &&
      other.calendarGapMinutes == calendarGapMinutes &&
      other.licensedCapacityMinutes == licensedCapacityMinutes &&
      other.usedMovableMinutes == usedMovableMinutes &&
      other.allocatedMinutes == allocatedMinutes &&
      other.remainingMinutes == remainingMinutes &&
      other.utilizationPermille == utilizationPermille &&
      other.overLicensedMinutes == overLicensedMinutes;

  @override
  int get hashCode => Object.hash(
    localDate,
    hardFreeMinutes,
    calendarGapMinutes,
    licensedCapacityMinutes,
    usedMovableMinutes,
    allocatedMinutes,
    remainingMinutes,
    utilizationPermille,
    overLicensedMinutes,
  );

  @override
  String toString() =>
      'DayCapacitySnapshot($localDate hard=$hardFreeMinutes '
      'gap=$calendarGapMinutes licensed=$licensedCapacityMinutes '
      'used=$usedMovableMinutes allocated=$allocatedMinutes '
      'remaining=$remainingMinutes util=$utilizationPermille‰)';
}

/// **不可变的逐日容量账本**：跨日分配的**唯一**容量来源（计划 §3.1 / 术语表 ALG-12）。
///
/// ## 为什么必须只有一份
///
/// 计划 §11 明令："不允许让容量分析器、诊断器和引擎各自重算一份空闲时间"。
/// 修复前 `TaskCapacityAnalyzer`、`TaskPlacementDiagnostics` 与引擎各算一套，
/// 于是"界面说还有 90 分钟、引擎说只剩 20 分钟"这种自相矛盾在真实运行中完全可能。
///
/// 因此账本**只从 `AvailabilityAnalysis` 与基线块构造一次**，
/// 之后 [allocate] / [release] 返回**新实例**，谁也不能就地改掉别人的视图。
final class DayCapacityLedger {
  DayCapacityLedger._(this._snapshots, this._anomalies);

  /// 从快照表构造（内部用；测试若需要伪造，用 [buildDayCapacityLedger]）。
  factory DayCapacityLedger.fromSnapshots(
    Iterable<DayCapacitySnapshot> snapshots,
  ) {
    final byDate = <DateTime, DayCapacitySnapshot>{};
    for (final snapshot in snapshots) {
      byDate[normalizeLocalDate(snapshot.localDate)] = snapshot;
    }
    return DayCapacityLedger._(UnmodifiableMapView(byDate), const []);
  }

  final Map<DateTime, DayCapacitySnapshot> _snapshots;

  /// 构造时发现的结构异常（目前只有"基线已用超过许可容量"一类）。
  final List<String> _anomalies;

  /// 全部日期，升序。
  List<DateTime> get localDates => _snapshots.keys.toList()..sort();

  /// 全部快照，按日期升序。
  List<DayCapacitySnapshot> get snapshots => [
    for (final date in localDates) _snapshots[date]!,
  ];

  /// 构造期发现的结构异常描述（空表示没有）。
  List<String> get anomalies => UnmodifiableListView(_anomalies);

  /// 是否检测到任何结构异常。
  bool get hasAnomaly => _anomalies.isNotEmpty;

  /// 取 [localDate] 的快照。**缺日抛 [StateError]**：账本必须覆盖窗口的全部本地日。
  DayCapacitySnapshot forDate(DateTime localDate) {
    final key = normalizeLocalDate(localDate);
    final snapshot = _snapshots[key];
    if (snapshot == null) {
      throw StateError(
        '容量账本缺少本地日期 ${key.year}-${key.month}-${key.day}；'
        '账本必须覆盖规划窗口涉及的每一个本地日',
      );
    }
    return snapshot;
  }

  /// [localDate] 还有多少可分配分钟；缺日抛 [StateError]。
  int remainingOn(DateTime localDate) => forDate(localDate).remainingMinutes;

  /// 给 [localDate] 许诺 [minutes] 分钟，返回**新账本**。
  ///
  /// **越界时抛 [StateError]，不静默夹紧**（计划 §6 账本契约）：
  /// 超额分配是算法缺陷，静默夹紧会把它变成"少排了几分钟"这种看不出原因的症状。
  DayCapacityLedger allocate(DateTime localDate, int minutes) =>
      _withAllocation(localDate, minutes, 'allocate');

  /// 把 [minutes] 分钟退回 [localDate]，返回**新账本**。
  ///
  /// 退回超过已分配量同样是缺陷（意味着有人在两次放置之间重复退款），因此抛错。
  DayCapacityLedger release(DateTime localDate, int minutes) =>
      _withAllocation(localDate, -minutes, 'release');

  DayCapacityLedger _withAllocation(
    DateTime localDate,
    int delta,
    String operation,
  ) {
    if (delta == 0) return this;
    final key = normalizeLocalDate(localDate);
    final current = forDate(key);
    final nextAllocated = current.allocatedMinutes + delta;
    if (nextAllocated < 0) {
      throw StateError(
        'release 超过已分配量：$key 已分配 ${current.allocatedMinutes} 分钟，'
        '试图退回 ${-delta} 分钟',
      );
    }
    if (delta > 0 && nextAllocated > _allocatableCeiling(current)) {
      throw StateError(
        'allocate 超过该日可用上限：$key 可分配 ${current.remainingMinutes} 分钟，'
        '试图分配 $delta 分钟',
      );
    }
    final gapRemaining = _gapRemaining(current, nextAllocated);
    final licensedRemaining = _licensedRemaining(current, nextAllocated);
    final remaining = gapRemaining < licensedRemaining
        ? gapRemaining
        : licensedRemaining;
    final updated = current.copyWith(
      allocatedMinutes: nextAllocated,
      remainingMinutes: remaining,
      utilizationPermille: _utilizationPermille(
        licensedCapacityMinutes: current.licensedCapacityMinutes,
        numerator: current.usedMovableMinutes + nextAllocated,
      ),
    );
    final next = Map<DateTime, DayCapacitySnapshot>.of(_snapshots);
    next[key] = updated;
    return DayCapacityLedger._(UnmodifiableMapView(next), _anomalies);
  }

  /// 该日还能被分配的上限（两个口径的最小值 + 已分配量）。
  static int _allocatableCeiling(DayCapacitySnapshot snapshot) {
    final gap = snapshot.calendarGapMinutes;
    final licensed =
        snapshot.licensedCapacityMinutes - snapshot.usedMovableMinutes;
    final available = gap < licensed ? gap : licensed;
    return (available < 0 ? 0 : available) + snapshot.allocatedMinutes;
  }

  static int _gapRemaining(DayCapacitySnapshot snapshot, int allocated) {
    final value = snapshot.calendarGapMinutes - allocated;
    return value < 0 ? 0 : value;
  }

  static int _licensedRemaining(DayCapacitySnapshot snapshot, int allocated) {
    final value =
        snapshot.licensedCapacityMinutes -
        snapshot.usedMovableMinutes -
        allocated;
    return value < 0 ? 0 : value;
  }

  @override
  String toString() => 'DayCapacityLedger(${snapshots.join(', ')})';
}

/// 从**唯一的** `AvailabilityAnalysis` 与基线块构造逐日容量账本
/// （计划 §6 / Task 3 Step 3）。
///
/// ## 输入为什么是这三个
///
/// - [availability]：同时提供**日硬空闲**（`hardFreeSlots`）与**视觉空白**（`slots`）。
///   修复前这两个口径只能靠"再扣一遍"推出来，而"再扣一遍"就是第二个事实源。
/// - [problem]：提供逐日策略（当日**可移动上限**）与"哪些块计入已用量"的判据。
/// - [baselineBlocks]：当前基线里占住时间的任务块。**锁定与钉住的块也算**——
///   它们占着这一天，只是不参与本轮分配（计划 §2 的 `usedMovableMinutes` 定义）。
///
/// ## 粒度对齐已经在分析层完成
///
/// 两组空闲都按**所属本地日**的粒度对齐过（计划 Task 2 Step 5），因此账本不再做
/// 第二次对齐——那会让"容量分析器、诊断器和引擎各算一份"重新出现。
DayCapacityLedger buildDayCapacityLedger({
  required ScheduleProblem problem,
  required AvailabilityAnalysis availability,
  required List<PlannedBlock> baselineBlocks,
  required TimeZoneDatabase zones,
}) {
  final hardFreeByDate = _minutesByLocalDate(availability.hardFreeSlots);
  final gapByDate = _minutesByLocalDate(availability.slots);
  final usedByDate = _usedMovableMinutesByLocalDate(
    problem: problem,
    baselineBlocks: baselineBlocks,
    zones: zones,
  );
  final anomalies = <String>[];
  final snapshots = <DateTime, DayCapacitySnapshot>{};

  for (final date in _datesOf(availability, hardFreeByDate, gapByDate)) {
    final policy = problem.policyForLocalDate(date);
    final hardFree = hardFreeByDate[date] ?? 0;
    final gap = gapByDate[date] ?? 0;
    final used = usedByDate[date] ?? 0;
    final dailyLimit = policy.resolvedRules.dailyMovableTaskLimitMinutes;
    final licensed = hardFree < dailyLimit ? hardFree : dailyLimit;
    final over = used > licensed ? used - licensed : 0;
    if (over > 0) {
      anomalies.add(
        '本地日期 $date 的基线已用 $used 分钟超过许可容量 $licensed 分钟（超出 $over 分钟）',
      );
    }
    final gapRemaining = gap < 0 ? 0 : gap;
    final licensedRemaining = licensed - used;
    final remaining =
        gapRemaining < (licensedRemaining < 0 ? 0 : licensedRemaining)
        ? gapRemaining
        : (licensedRemaining < 0 ? 0 : licensedRemaining);
    snapshots[date] = DayCapacitySnapshot(
      localDate: date,
      hardFreeMinutes: hardFree,
      calendarGapMinutes: gap,
      licensedCapacityMinutes: licensed,
      usedMovableMinutes: used,
      allocatedMinutes: 0,
      remainingMinutes: remaining,
      utilizationPermille: _utilizationPermille(
        licensedCapacityMinutes: licensed,
        numerator: used,
      ),
      overLicensedMinutes: over,
    );
  }

  return DayCapacityLedger._(
    UnmodifiableMapView(snapshots),
    UnmodifiableListView(anomalies),
  );
}

/// 该日应当先作为**软目标**保留的恢复余量（计划 §3.7 / Task 3 Step 3）。
///
/// `min(30, floor(licensedCapacityMinutes * 10% / granularity) * granularity)`。
/// 由账本的许可容量与当天粒度算出，因此装配层不必自己再推一遍。
int softReserveTargetForSnapshot(
  DayCapacitySnapshot snapshot,
  int granularity,
) => softReserveTargetFor(
  licensedCapacityMinutes: snapshot.licensedCapacityMinutes,
  granularityMinutes: granularity,
);

/// 日负载率：`ceil(numerator * 1000 / licensed)`，**不除零**（计划 §2）。
///
/// - `licensed == 0 && numerator == 0` ⇒ `0`；
/// - `licensed == 0 && numerator > 0` ⇒ `1001`（结构异常：没有容量却有占用）。
int _utilizationPermille({
  required int licensedCapacityMinutes,
  required int numerator,
}) {
  if (licensedCapacityMinutes <= 0) return numerator <= 0 ? 0 : 1001;
  if (numerator <= 0) return 0;
  return (numerator * 1000 + licensedCapacityMinutes - 1) ~/
      licensedCapacityMinutes;
}

/// 统计一组空闲切片按本地日归集的分钟数。
Map<DateTime, int> _minutesByLocalDate(List<AvailabilitySlot> slots) {
  final result = <DateTime, int>{};
  for (final slot in slots) {
    final date = normalizeLocalDate(slot.localDate);
    result[date] = (result[date] ?? 0) + slot.durationMinutes;
  }
  return result;
}

/// 基线里**计入当日可移动上限**的任务块分钟（计划 §2 的 `usedMovableMinutes`）。
///
/// 判据与 `PlanValidator`、放置循环**共用 `movableMinutesByLocalDate`**
/// （`candidate_eligibility.dart`）：锁定块与"拖动了但没锁定"的块都算。
/// 三处各写一遍就是三套口径，而它们必须给出同一个答案。
Map<DateTime, int> _usedMovableMinutesByLocalDate({
  required ScheduleProblem problem,
  required List<PlannedBlock> baselineBlocks,
  required TimeZoneDatabase zones,
}) => movableMinutesByLocalDate(
  problem: problem,
  zones: zones,
  blocks: baselineBlocks,
);

/// 账本需要覆盖的日期集合：**两组空闲出现过的日期之并**。
///
/// 不用"窗口起止各取本地日再逐日推进"：窗口可能是"周四 20:00 到下周一 00:00"
/// 这种形状，首日只有半个晚上，而 `AvailabilitySlot.localDate` 已经按本地日切好片。
Set<DateTime> _datesOf(
  AvailabilityAnalysis availability,
  Map<DateTime, int> hardFreeByDate,
  Map<DateTime, int> gapByDate,
) {
  final dates = <DateTime>{...hardFreeByDate.keys, ...gapByDate.keys};
  for (final slot in availability.slots) {
    dates.add(normalizeLocalDate(slot.localDate));
  }
  for (final slot in availability.hardFreeSlots) {
    dates.add(normalizeLocalDate(slot.localDate));
  }
  return dates;
}
