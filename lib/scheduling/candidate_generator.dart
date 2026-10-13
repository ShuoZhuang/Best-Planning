import 'dart:collection';

import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

final class SchedulingCandidate {
  const SchedulingCandidate({
    required this.id,
    required this.taskId,
    required this.range,
    required this.localDate,
  });

  final String id;
  final String taskId;
  final TimeRange range;
  final DateTime localDate;

  DateTime get startUtc => range.startUtc;
  DateTime get endUtc => range.endUtc;
  int get durationMinutes => range.durationMinutes;
}

final class CandidateGenerator {
  const CandidateGenerator({this.granularityMinutes = 5})
    : assert(granularityMinutes > 0);

  final int granularityMinutes;

  /// 以**当前剩余量**生成候选（计划 `2026-10-13-…-repair.md` §2.1，冻结决策）。
  ///
  /// **`remainingMinutes` 没有默认值**：它是本函数与调用方之间的契约，不是可选调优。
  /// 给默认值（哪怕等于 `task.requiredMinutes`）会让"漏改的调用点"静默退回旧语义，
  /// 而旧语义正是 R3 的根因——引擎在进入放置循环**之前**只生成一次候选，之后每一轮
  /// 都复用那份"基于初始总量"的候选集，于是 100 分钟的任务永远看不见最后那 10 分钟。
  ///
  /// 契约：
  /// - `0 <= remainingMinutes <= task.requiredMinutes`，否则抛 [ArgumentError]；
  /// - **连续任务**只有 `remainingMinutes == task.requiredMinutes` 时产出那一个完整候选，
  ///   否则返回空（已放置过一段的连续任务不再迭代）；
  /// - **可拆分任务**的上限用 `remainingMinutes`，不再读 `task.requiredMinutes`；
  /// - `remainingMinutes < task.minChunkMinutes` 时唯一候选时长是
  ///   [shortRemainderAllowance]（粒度下的剩余量），结果为 0 或超过 `maxChunkMinutes`
  ///   时返回空——如实报缺口，不伪造片段。
  List<SchedulingCandidate> generate(
    SchedulableTask task,
    List<AvailabilitySlot> slots, {
    required int remainingMinutes,
  }) {
    final durations = _candidateDurations(
      task,
      remainingMinutes: remainingMinutes,
    );
    final candidates = <SchedulingCandidate>[];

    for (final slot in slots) {
      // 只在该日**本地星期**被允许时产出候选（路线图 §3.4 "仅指定星期"）。
      // 用 `slot.localDate` 而不是把 UTC 时刻换算一遍：可用时段本来就是这个本地日的切片，
      // 再换一次时区只会在夏令时切换日引入第二个真相。
      if (!task.allowsWeekday(slot.localDate.weekday)) continue;
      final availableFrom = task.availableFromUtc;
      final earliestStart = availableFrom == null
          ? slot.startUtc
          : _laterOf(
              slot.startUtc,
              _roundUtcUp(availableFrom, granularityMinutes),
            );
      for (final duration in durations) {
        if (duration > slot.durationMinutes) continue;
        final latestStart = slot.endUtc.subtract(Duration(minutes: duration));
        if (earliestStart.isAfter(latestStart)) continue;
        for (
          var start = earliestStart;
          !start.isAfter(latestStart);
          start = start.add(Duration(minutes: granularityMinutes))
        ) {
          final range = TimeRange(
            startUtc: start,
            endUtc: start.add(Duration(minutes: duration)),
          );
          candidates.add(
            SchedulingCandidate(
              id: '${task.id}:${start.microsecondsSinceEpoch}:$duration',
              taskId: task.id,
              range: range,
              localDate: slot.localDate,
            ),
          );
        }
      }
    }

    candidates.sort((a, b) {
      final startOrder = a.startUtc.compareTo(b.startUtc);
      if (startOrder != 0) return startOrder;
      final durationOrder = a.durationMinutes.compareTo(b.durationMinutes);
      if (durationOrder != 0) return durationOrder;
      return a.id.compareTo(b.id);
    });
    return UnmodifiableListView(candidates);
  }

  List<int> _candidateDurations(
    SchedulableTask task, {
    required int remainingMinutes,
  }) {
    // 入参契约在这里**唯一**检查一次：上限、下限与非法值都只有这一处判据。
    if (remainingMinutes < 0 || remainingMinutes > task.requiredMinutes) {
      throw ArgumentError.value(
        remainingMinutes,
        'remainingMinutes',
        '必须满足 0 <= remainingMinutes <= task.requiredMinutes'
            '（${task.requiredMinutes}）',
      );
    }
    if (task.splitMode == TaskSplitMode.continuous) {
      // 连续任务只有"一次做完"一种形态：`remainingMinutes == requiredMinutes`
      // 时那一个整块就是候选，已经排过一段之后（remaining 更小）不再迭代。
      if (remainingMinutes != task.requiredMinutes) return const [];
      return remainingMinutes % granularityMinutes == 0
          ? [remainingMinutes]
          : const [];
    }

    if (remainingMinutes <= 0) return const [];

    // **有效最小片段 = min(配置的最小片段, 当前剩余量)**（用户写进路线图 Task 12A 的规则）。
    //
    // 修的是什么：原先 `minimum = roundUp(minChunk)`，而 `maximum = roundDown(min(maxChunk,
    // requiredMinutes))`。一个 15 分钟的可拆分任务配上默认片段 30–90 分钟时 minimum=30 > maximum=15，
    // `duration <= maximum` 直接不成立 ⇒ **一个候选都不生成** ⇒ 任务既出现在"新增"里又出现在
    // "未安排"里。实测 `required=15 min=30 max=90 → scheduled=0 shortage=15`。
    //
    // 为什么宽免只针对这种情况：`remainingMinutes` 是**本次排程的剩余量**，不是任务的总时长
    // （180 → 100 → 15）。所以"最后一段"是每次排程时才知道的事。当剩余量还凑得出一个最小片段时
    // （100 分钟），下限必须照旧生效——否则每一次排入都会用一个短片段去满足最小片段约束，
    // 那等于把这条约束取消掉。只有当剩余量**本身**短于最小片段时，它自己就是最后一段，
    // 此时正确的处置是让这一段短于下限，而不是拒绝安排。
    //
    // **1.4 冻结决策之后，短余量的取值由 `shortRemainderAllowance` 唯一决定**，与
    // `PlanValidator.validatePlannedChunkSet` / `isValidPlannedChunk` 读的是同一个函数——
    // 三处各写一遍正是 R4 的成因。
    final isShortRemainder = remainingMinutes < task.minChunkMinutes;
    final minimum = isShortRemainder
        ? shortRemainderAllowance(
            requiredMinutes: remainingMinutes,
            granularityMinutes: granularityMinutes,
          )
        : _roundUp(task.minChunkMinutes, granularityMinutes);
    // 上限用 `remainingMinutes`（**不再是 `task.requiredMinutes`**）：那一份旧写法会让
    // 剩余 30 分钟时的候选集仍以 90 分钟起步，于是"每轮重算"名存实亡。
    final maximum = _roundDown(
      task.maxChunkMinutes < remainingMinutes
          ? task.maxChunkMinutes
          : remainingMinutes,
      granularityMinutes,
    );
    // 剩余量不足一个粒度（例如 3 分钟、粒度 5 分钟）时 `minimum` 与 `maximum` 都为 0：
    // 这里**如实返回空**，由缺口机制汇报容量不足，而不是伪造一个片段。
    if (minimum <= 0 || maximum <= 0) return const [];
    if (minimum > maximum) return const [];
    return [
      for (
        var duration = minimum;
        duration <= maximum;
        duration += granularityMinutes
      )
        duration,
    ];
  }
}

int _roundUp(int value, int step) => ((value + step - 1) ~/ step) * step;
int _roundDown(int value, int step) => (value ~/ step) * step;

DateTime _laterOf(DateTime first, DateTime second) =>
    first.isAfter(second) ? first : second;

DateTime _roundUtcUp(DateTime value, int stepMinutes) {
  final step = Duration(minutes: stepMinutes).inMicroseconds;
  final rounded = ((value.microsecondsSinceEpoch + step - 1) ~/ step) * step;
  return DateTime.fromMicrosecondsSinceEpoch(rounded, isUtc: true);
}
