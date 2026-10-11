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
  List<AvailabilitySlot> build(AvailabilityInput input) {
    final busy = _merge(
      [
            ...input.fixedIntervals,
            ...input.protectedIntervals,
            ...input.lockedBlocks,
            ..._sleepIntervals(input),
          ]
          .map((range) => _intersection(range, input.planningWindow))
          .nonNulls
          .toList(),
    );

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

    return List.unmodifiable(output);
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
