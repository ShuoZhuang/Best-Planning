import 'dart:collection';

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/protected_time_expander.dart';

final class AvailabilityInput {
  AvailabilityInput({
    required this.planningWindow,
    required this.timeZoneId,
    required this.rules,
    List<TimeRange> fixedIntervals = const [],
    List<TimeRange> protectedIntervals = const [],
    List<TimeRange> lockedBlocks = const [],
    List<TimeRange> chargedMovableBlocks = const [],
  }) : fixedIntervals = UnmodifiableListView(fixedIntervals),
       protectedIntervals = UnmodifiableListView(protectedIntervals),
       lockedBlocks = UnmodifiableListView(lockedBlocks),
       chargedMovableBlocks = UnmodifiableListView(chargedMovableBlocks);

  final TimeRange planningWindow;
  final String timeZoneId;
  final PlanningRules rules;
  final List<TimeRange> fixedIntervals;
  final List<TimeRange> protectedIntervals;
  final List<TimeRange> lockedBlocks;

  /// 已经占住时间、**但落地为未锁定**的块（FR-CAL-05 里"拖动了但没锁定"的那一支）。
  ///
  /// 它们与 `lockedBlocks` 一样从可用时间里扣除（因此候选不会压上去），但**必须计入当日
  /// 可移动任务预算**：`PlanValidator` 是按"未锁定块"统计每日上限的，若这里不扣，同一段时长
  /// 在两侧算法不同，会凭空产生 `dailyLimitExceeded`，把一次合法的手动移动判为无效提案。
  final List<TimeRange> chargedMovableBlocks;
}

final class AvailabilitySlot {
  const AvailabilitySlot({required this.range, required this.localDate});

  final TimeRange range;
  final DateTime localDate;

  DateTime get startUtc => range.startUtc;
  DateTime get endUtc => range.endUtc;
  int get durationMinutes => range.durationMinutes;

  @override
  bool operator ==(Object other) =>
      other is AvailabilitySlot &&
      other.range == range &&
      other.localDate == localDate;

  @override
  int get hashCode => Object.hash(range, localDate);
}

/// 一段空闲被**哪几类**硬占用挡住的标签（1.8.0，「可见空闲却报容量不足」专项）。
///
/// 四个取值与 `ScheduleProblem` 的四类占用一一对应。睡眠之所以与保护时间分开：
/// 它们的来源、可编辑性与用户要做的处置都不同（"早点睡"与"改保护时间"是两回事）。
enum AvailabilityBlockerKind {
  /// 固定日程（含课表课程结束后的缓冲）。
  fixed,

  /// 保护时间：规则来源（午餐／晚餐／固定休息）与用户自建的日历事项。
  protected,

  /// 睡眠。
  sleep,

  /// 锁定计划块，以及"拖动了但没锁定"（`chargedMovableBlocks`）的那些。
  locked,
}

/// 一段被占用且**带来源标签**的区间。
///
/// [kinds] 是集合而不是单值：同一段分钟可能同时被固定日程与保护时间覆盖
/// （课表的缓冲时间叠在午餐上），而容量只能扣一次。修复前这件事没有任何可核对的形式 ——
/// "总容量扣了几次"只能靠读代码猜。
final class BlockedAvailabilitySegment {
  BlockedAvailabilitySegment({
    required this.range,
    required Set<AvailabilityBlockerKind> kinds,
  }) : kinds = UnmodifiableSetView(Set.of(kinds));

  final TimeRange range;
  final Set<AvailabilityBlockerKind> kinds;

  int get durationMinutes => range.durationMinutes;
}

/// 规划窗口内空闲与占用的**完整分析**（`AvailabilityBuilder.build` 的详细形式）。
final class AvailabilityAnalysis {
  AvailabilityAnalysis({
    required List<AvailabilitySlot> slots,
    required List<BlockedAvailabilitySegment> blockedSegments,
    required this.calendarGapMinutes,
  }) : slots = UnmodifiableListView(List.of(slots)),
       blockedSegments = UnmodifiableListView(List.of(blockedSegments));

  /// 与 `build(input)` **逐值相同**的空闲时段（见 `build` 的转发）。
  final List<AvailabilitySlot> slots;

  /// 规划窗口内被占用的分段，带来源标签，按起点升序、互不重叠。
  final List<BlockedAvailabilitySegment> blockedSegments;

  /// 规划窗口扣除全部占用（含 `chargedMovableBlocks`）并按粒度对齐后的空闲分钟并集。
  ///
  /// **它恒等于 `slots.sum(durationMinutes)`**，这条等式由
  /// `availability_builder_test.dart` 钉住：两个数字一旦不一致，就说明有人把
  /// "空闲"算成了两件事。
  final int calendarGapMinutes;
}

final class AvailabilityBuilder {
  const AvailabilityBuilder(this._zones);

  final TimeZoneDatabase _zones;

  /// 构造规划窗口内的**全部真实空闲区间**，按本地日期切片。
  ///
  /// ## 不再按每日上限截断候选时间轴（1.7.1 修复，计划 §2.4 / Task 2）
  ///
  /// 此前这里把 `dailyMovableTaskLimitMinutes` 当成"最多保留多少分钟空闲候选"，
  /// 从清晨开始依次消费：一天上限 360 分钟时，前 360 分钟空闲被保留，**后面的空闲区间
  /// 直接不进入候选集**。
  ///
  /// 三条理由说明那不是这条规则的含义：
  ///
  /// 1. **上限约束的是最终结果，不是可见性。** 它的语义是"这一天最终安排的可移动任务总时长
  ///    不超过 N"，而 `PlanValidator` 早就是这条约束的最终防线（按未锁定块汇总）。
  ///    在构造阶段把它当预算花掉，等于用"少看见一些空档"来实现一条本该在结果上校验的规则。
  /// 2. **候选可见性会依赖空档顺序。** 同样是一天 540 分钟空闲，拆成"早中晚三段各 180"
  ///    与"一整段 540"，旧实现给出的候选集完全不同——而真实可用时间是一样的。
  /// 3. **用户看到的空闲与引擎能选的空闲必须一致。** 界面按真实空闲画，引擎按截断后的候选
  ///    排，于是"这块明明空着，为什么排不进去"就成了无法解释的现象。
  ///
  /// 因此现在只做四件事：规划窗口裁剪、固定/保护/睡眠/锁定区间扣除、粒度对齐、本地日期切片。
  ///
  /// **注意 `chargedMovableBlocks` 仍然扣除**：它们占住时间（候选不会压上去），而它们计入
  /// 每日上限的事由 `ScheduleEngine` 与 `PlanValidator` 负责——见 `AvailabilityInput` 的说明。
  ///
  /// **本方法是 [analyze] 的转发**（1.8.0 专项）：详细分析要产出同一批空闲时段，
  /// 若两处各实现一遍，"界面看到的空闲"与"容量证据里的空闲"迟早会漂。
  /// 这条转发由 `availability_builder_test.dart` 的逐值一致性用例守着。
  List<AvailabilitySlot> build(AvailabilityInput input) => analyze(input).slots;

  /// [build] 的详细形式：除空闲时段外，还返回带来源标签的占用分段与空闲分钟总数。
  AvailabilityAnalysis analyze(AvailabilityInput input) {
    // ── 带标签的占用合并（扫线）──────────────────────────────────────────────
    //
    // **同一分钟只从总容量扣一次**：先把四类"命名占用"按区间合并，合并时保留各自的标签
    // 集合；`chargedMovableBlocks` 只是占用（没有标签），单独合并后与前者求并。
    //
    // 合并规则（与 `_merge` 完全一致，因此 `slots` 不会因为多了标签而漂）：
    // `next.start <= current.end` 视为相接，取较晚的结束时刻。
    final labeled = <TimeRange, Set<AvailabilityBlockerKind>>{};
    void addLabeled(Iterable<TimeRange> ranges, AvailabilityBlockerKind kind) {
      for (final range in ranges) {
        final clipped = _intersection(range, input.planningWindow);
        if (clipped == null) continue;
        labeled.update(
          clipped,
          (kinds) => kinds..add(kind),
          ifAbsent: () => {kind},
        );
      }
    }

    addLabeled(input.fixedIntervals, AvailabilityBlockerKind.fixed);
    addLabeled(input.protectedIntervals, AvailabilityBlockerKind.protected);
    addLabeled(_sleepIntervals(input), AvailabilityBlockerKind.sleep);
    addLabeled(input.lockedBlocks, AvailabilityBlockerKind.locked);

    // 带标签的两两合并：相邻或重叠且标签集合**相同**的区间先各自合并，
    // 再把"标签集合不同但区间重叠"的部分拆开——拆开是必要的，否则一段
    // "固定日程 + 保护时间"重叠 30 分钟的区间会丢掉其中一个标签。
    final blockedSegments = _labeledSegments(labeled);

    final charged = _merge([
      for (final range in input.chargedMovableBlocks)
        ?_intersection(range, input.planningWindow),
    ]);
    // 空闲 = 窗口 − （带标签占用 ∪ charged）。
    //
    // 用**并集**而不是把两组分别求补再相减：后者会把"两组重叠的那几分钟"扣两次，
    // 而"同一分钟只能扣一次"是这一层的硬约束。
    final busy = _merge([
      for (final segment in blockedSegments) segment.range,
      ...charged,
    ]);

    final output = <AvailabilitySlot>[];
    var localDate = _dateOnly(
      _zones.toLocal(input.planningWindow.startUtc, input.timeZoneId),
    );
    final lastLocalDate = _dateOnly(
      _zones.toLocal(
        input.planningWindow.endUtc.subtract(const Duration(microseconds: 1)),
        input.timeZoneId,
      ),
    );
    final granularity = input.rules.granularityMinutes;

    while (!localDate.isAfter(lastLocalDate)) {
      final dayStart = _zones.localMidnightToUtc(localDate, input.timeZoneId);
      final nextDate = localDate.add(const Duration(days: 1));
      final dayEnd = _zones.localMidnightToUtc(nextDate, input.timeZoneId);
      final dayWindow = _intersection(
        TimeRange(startUtc: dayStart, endUtc: dayEnd),
        input.planningWindow,
      );
      if (dayWindow != null) {
        final dayBusy = busy
            .map((range) => _intersection(range, dayWindow))
            .nonNulls
            .toList();
        for (final range in _complement(dayWindow, dayBusy)) {
          // 粒度对齐只缩短**尾部**：空闲区间的起点不动，因此候选起点仍然落在真实空闲内。
          // 对齐后不足一个粒度的碎片直接丢弃——它连最小片段都放不下。
          final alignedMinutes =
              (range.durationMinutes ~/ granularity) * granularity;
          if (alignedMinutes <= 0) continue;
          output.add(
            AvailabilitySlot(
              localDate: localDate,
              range: TimeRange(
                startUtc: range.startUtc,
                endUtc: range.startUtc.add(Duration(minutes: alignedMinutes)),
              ),
            ),
          );
        }
      }
      localDate = nextDate;
    }

    final slots = UnmodifiableListView(output);
    return AvailabilityAnalysis(
      slots: slots,
      blockedSegments: blockedSegments,
      calendarGapMinutes: slots.fold<int>(
        0,
        (sum, slot) => sum + slot.durationMinutes,
      ),
    );
  }

  List<TimeRange> _sleepIntervals(AvailabilityInput input) =>
      // **睡眠展开只有一处实现**（`ProtectedTimeExpander.sleep`）。
      // 此前这里是自带的一份同样逻辑，而 `ScheduleProblem.protectedIntervals`
      // 里**没有**睡眠 —— 于是"容量认为睡眠不可用、校验却认为压上去没关系"，
      // 两处口径不一致（用户第 65 轮复核第 3 条）。
      // 现在两边共用同一份展开，口径不可能再漂。
      ProtectedTimeExpander(_zones)
          .sleep(
            rules: input.rules,
            startUtc: input.planningWindow.startUtc,
            endUtc: input.planningWindow.endUtc,
            timeZoneId: input.timeZoneId,
          )
          .map((interval) => interval.range)
          .toList();
}

List<TimeRange> _merge(List<TimeRange> ranges) {
  if (ranges.isEmpty) return const [];
  ranges.sort((a, b) => a.startUtc.compareTo(b.startUtc));
  final merged = <TimeRange>[];
  var current = ranges.first;
  for (final next in ranges.skip(1)) {
    if (!next.startUtc.isAfter(current.endUtc)) {
      current = TimeRange(
        startUtc: current.startUtc,
        endUtc: next.endUtc.isAfter(current.endUtc)
            ? next.endUtc
            : current.endUtc,
      );
    } else {
      merged.add(current);
      current = next;
    }
  }
  merged.add(current);
  return merged;
}

/// 把"区间 → 标签集合"化成**互不重叠、各带完整标签集合**的分段（扫线）。
///
/// 做法是标准的端点切分：取全部起点与终点作为切点，每一对相邻切点之间的分钟数
/// **必然**被同一组区间覆盖，因此它的标签集合是定值。这样重叠的固定日程与保护时间
/// 会得到"两者都在"的一段，而不是丢掉其中一个标签——容量仍然只扣一次（它们被并成了一段）。
///
/// 紧邻且标签集合相同的分段会合并，于是输出是"能合并的都合并了"的最小分段数，
/// 结果与输入顺序无关（切点先排序，标签集合是数学上的交集）。
List<BlockedAvailabilitySegment> _labeledSegments(
  Map<TimeRange, Set<AvailabilityBlockerKind>> labeled,
) {
  if (labeled.isEmpty) return const [];
  final boundaries = <DateTime>{};
  for (final range in labeled.keys) {
    boundaries
      ..add(range.startUtc)
      ..add(range.endUtc);
  }
  final cuts = boundaries.toList()..sort();
  final result = <BlockedAvailabilitySegment>[];
  for (var index = 0; index + 1 < cuts.length; index++) {
    final start = cuts[index];
    final end = cuts[index + 1];
    if (!end.isAfter(start)) continue;
    final kinds = <AvailabilityBlockerKind>{};
    for (final entry in labeled.entries) {
      // 该区间覆盖"这一整对切点之间"的判据：起点不晚于 start，且终点不早于 end。
      // （切点只有这一批区间的端点，因此不存在"只覆盖一半"的情况。）
      if (entry.key.startUtc.isAfter(start)) continue;
      if (entry.key.endUtc.isBefore(end)) continue;
      kinds.addAll(entry.value);
    }
    if (kinds.isEmpty) continue;
    final previous = result.isEmpty ? null : result.last;
    if (previous != null &&
        !previous.range.endUtc.isBefore(start) &&
        previous.kinds.length == kinds.length &&
        previous.kinds.containsAll(kinds)) {
      result[result.length - 1] = BlockedAvailabilitySegment(
        range: TimeRange(startUtc: previous.range.startUtc, endUtc: end),
        kinds: kinds,
      );
      continue;
    }
    result.add(
      BlockedAvailabilitySegment(
        range: TimeRange(startUtc: start, endUtc: end),
        kinds: kinds,
      ),
    );
  }
  return result;
}

List<TimeRange> _complement(TimeRange window, List<TimeRange> busy) {
  final output = <TimeRange>[];
  var cursor = window.startUtc;
  for (final interval in _merge(busy)) {
    if (interval.startUtc.isAfter(cursor)) {
      output.add(TimeRange(startUtc: cursor, endUtc: interval.startUtc));
    }
    if (interval.endUtc.isAfter(cursor)) cursor = interval.endUtc;
  }
  if (cursor.isBefore(window.endUtc)) {
    output.add(TimeRange(startUtc: cursor, endUtc: window.endUtc));
  }
  return output;
}

TimeRange? _intersection(TimeRange a, TimeRange b) {
  final start = a.startUtc.isAfter(b.startUtc) ? a.startUtc : b.startUtc;
  final end = a.endUtc.isBefore(b.endUtc) ? a.endUtc : b.endUtc;
  return end.isAfter(start) ? TimeRange(startUtc: start, endUtc: end) : null;
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
