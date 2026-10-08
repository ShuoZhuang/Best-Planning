import 'dart:collection';

import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
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

  List<SchedulingCandidate> generate(
    SchedulableTask task,
    List<AvailabilitySlot> slots,
  ) {
    final durations = _candidateDurations(task);
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

  List<int> _candidateDurations(SchedulableTask task) {
    if (task.splitMode == TaskSplitMode.continuous) {
      return task.requiredMinutes % granularityMinutes == 0
          ? [task.requiredMinutes]
          : const [];
    }

    // **有效最小片段 = min(配置的最小片段, 剩余量)**（用户写进路线图 Task 12A 的规则）。
    //
    // 修的是什么：原先 `minimum = roundUp(minChunk)`，而 `maximum = roundDown(min(maxChunk,
    // requiredMinutes))`。一个 15 分钟的可拆分任务配上默认片段 30–90 分钟时 minimum=30 > maximum=15，
    // `duration <= maximum` 直接不成立 ⇒ **一个候选都不生成** ⇒ 任务既出现在"新增"里又出现在
    // "未安排"里。实测 `required=15 min=30 max=90 → scheduled=0 shortage=15`。
    //
    // 为什么宽免只针对这种情况：`requiredMinutes` 是**本次排程的剩余量**，不是任务的总时长
    // （180 → 100 → 15）。所以"最后一段"是每次排程时才知道的事。当剩余量还凑得出一个最小片段时
    // （100 分钟），下限必须照旧生效——否则每一次排入都会用一个短片段去满足最小片段约束，
    // 那等于把这条约束取消掉。只有当剩余量**本身**短于最小片段时，它自己就是最后一段，
    // 此时正确的处置是让这一段短于下限，而不是拒绝安排。
    final effectiveMinimum = task.minChunkMinutes < task.requiredMinutes
        ? task.minChunkMinutes
        : task.requiredMinutes;
    // **钳制过的那一支用 `_roundDown`，不钳制的那一支仍用 `_roundUp`**——两者方向相反是有理由的：
    // · 配置的下限（30 分钟）向上取整到粒度，保证"至少 30 分钟"这条约束不被悄悄放松；
    // · 取"剩余量本身"时**不能向上取整**：余 12 分钟、粒度 5 分钟，向上取成 15 会超过剩余量，
    //   于是 `minimum > maximum` 又变成零候选（实测）。向下取整到 10 才是既合法又不超排的量。
    final minimum = task.minChunkMinutes < task.requiredMinutes
        ? _roundUp(effectiveMinimum, granularityMinutes)
        : _roundDown(effectiveMinimum, granularityMinutes);
    final maximum = _roundDown(
      task.maxChunkMinutes < task.requiredMinutes
          ? task.maxChunkMinutes
          : task.requiredMinutes,
      granularityMinutes,
    );
    // 剩余量不足一个粒度（例如 3 分钟、粒度 5 分钟）时 `maximum` 为 0：
    // 这里**如实返回空**，由缺口机制汇报容量不足，而不是伪造一个片段。
    if (maximum <= 0) return const [];
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
