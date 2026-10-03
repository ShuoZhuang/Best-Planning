import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';

/// 计算设计 §5.4「任务期望时段」因子的得分。
///
/// 期望时段是任务所在**本地日**的本地分钟区间（例如 09:00–12:00）。分数按"候选落在
/// 期望时段内的时长占自身时长的比例"在权重区间内线性插值：
///
/// - 区间为空（用户没有表达偏好）→ 返回 0，因子中性，不参与排序；
/// - 候选完全落在区间内 → [maximumScore]；
/// - 完全不沾边 → [minimumScore]；
/// - 部分落在区间内 → 按比例取中间值（半程居中）。
///
/// 用比例而不是布尔命中，是为了让"部分满足"严格优于"完全不满足"：当期望时段已被
/// 占用、无法完全满足时，引擎仍会选择偏离最小的位置，而不是把区间外的候选一律视为
/// 等价。同时"表达了偏好但落空"（[minimumScore]）低于"没有偏好"（0），这是设计
/// 意图——用户主动表达的诉求落空，应当比没有表达更差。
///
/// 区间经 `localDateTimeToUtc` 换算，因此夏令时切换当天仍按用户看到的钟点生效（当天
/// 只有 23 或 25 小时时，墙上时间仍是用户期望的那个钟点）。
///
/// **锚定日**：跨越本地午夜的区间（如 22:00–02:00）会被
/// `LocalTimeRange.splitAtMidnight` 拆成"当日 22:00–24:00"与"次日 00:00–02:00"
/// 两段，因此凌晨 01:00 的候选其实属于**前一天**锚定的那个窗口。只看候选自身所在
/// 日期会把这种候选判成完全落空，所以这里同时按候选本地日与其前一天各算一次，取
/// 重叠时间较长的一次。对不跨午夜的区间，前一天的锚定不会产生重叠，结果不变。
///
/// [candidateRange] 与 [localDate] 必须描述同一个候选：`localDate` 是候选起始时刻所在
/// 的本地日期。
int preferredTimeScore({
  required LocalTimeRange? window,
  required TimeRange candidateRange,
  required DateTime localDate,
  required String timeZoneId,
  required TimeZoneDatabase zones,
  required int minimumScore,
  required int maximumScore,
}) {
  if (window == null) return 0;
  final durationMinutes = candidateRange.durationMinutes;
  if (durationMinutes <= 0) return 0;

  var overlapMinutes = 0;
  for (final anchor in [localDate, _shiftLocalDate(localDate, -1)]) {
    for (final segment in window.splitAtMidnight()) {
      final segmentDate = _shiftLocalDate(anchor, segment.dayOffset);
      final startUtc = zones.localDateTimeToUtc(
        segmentDate,
        segment.startMinute,
        timeZoneId,
      );
      // 段的终点可以等于一日分钟数（24:00），表示次日的本地零点：像 09:00–24:00
      // 这样的区间不跨午夜，但终点是 1440。`localDateTimeToUtc` 只接受 [0, 1439]，
      // 因此这种情况必须换算成次日零点，否则会抛参数错误。
      final endUtc = segment.endMinute == LocalTimeRange.minutesPerDay
          ? zones.localMidnightToUtc(
              _shiftLocalDate(segmentDate, 1),
              timeZoneId,
            )
          : zones.localDateTimeToUtc(
              segmentDate,
              segment.endMinute,
              timeZoneId,
            );
      final overlap = _overlapMinutes(
        candidateRange,
        TimeRange(startUtc: startUtc, endUtc: endUtc),
      );
      if (overlap > overlapMinutes) overlapMinutes = overlap;
    }
  }

  if (overlapMinutes <= 0) return minimumScore;
  final permille = overlapMinutes >= durationMinutes
      ? 1000
      : overlapMinutes * 1000 ~/ durationMinutes;
  return minimumScore + ((maximumScore - minimumScore) * permille) ~/ 1000;
}

int _overlapMinutes(TimeRange a, TimeRange b) {
  final start = a.startUtc.isAfter(b.startUtc) ? a.startUtc : b.startUtc;
  final end = a.endUtc.isBefore(b.endUtc) ? a.endUtc : b.endUtc;
  if (!end.isAfter(start)) return 0;
  return end.difference(start).inMinutes;
}

/// 按本地日历日位移，不用 `Duration`：夏令时当天的本地日长是 23 或 25 小时，
/// 用 `add(const Duration(days: 1))` 会在切换日落到错误日期。
DateTime _shiftLocalDate(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);
