import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';

/// 保护时间窗口之间**重叠**的一条结构化事实（课程与保护时间管理修复计划 Task 9）。
///
/// **为什么必须结构化**：计划 §2.4 要求"早餐与睡眠、午餐或其它保护窗口重叠时
/// **必须在保存前指出具体重叠区间**；不能静默合并或重复计算保护分钟"。
/// 一句"保存失败"或"时间冲突"没有告诉用户改哪一个、改多少——
/// 而"重叠 30 分钟"能。
final class ProtectedTimeOverlap {
  const ProtectedTimeOverlap({
    required this.kind,
    required this.otherKind,
    required this.thisRange,
    required this.otherRange,
    required this.overlapStartMinute,
    required this.overlapEndMinute,
  });

  /// 本次编辑的那一类（例如 `breakfast`）。
  final String kind;

  /// 与它重叠的那一类（`sleep` 或另一类保护时间）。
  final String otherKind;

  /// 两个完整区间，用于拼出用户看得懂的那句话。
  final LocalTimeRange thisRange;
  final LocalTimeRange otherRange;

  /// 重叠区间（本地分钟）。跨午夜时 `end < start`，与 [LocalTimeRange] 同一约定。
  final int overlapStartMinute;
  final int overlapEndMinute;

  int get overlapMinutes => overlapEndMinute > overlapStartMinute
      ? overlapEndMinute - overlapStartMinute
      : LocalTimeRange.minutesPerDay - overlapStartMinute + overlapEndMinute;

  /// 用户可见的一句：**带具体区间与分钟数**。
  ///
  /// 例：`早餐保护 07:30–08:00 与睡眠 23:30–08:00 重叠 30 分钟`
  /// （计划 Task 9 Step 3 的原句）。
  String describe() =>
      '${_label(kind)} ${_hhmm(thisRange.startMinute)}–'
      '${_hhmm(thisRange.endMinute)} 与${_label(otherKind)} '
      '${_hhmm(otherRange.startMinute)}–${_hhmm(otherRange.endMinute)} '
      '重叠 $overlapMinutes 分钟';

  static String _label(String key) => switch (key) {
    'breakfast' => '早餐保护',
    'lunch' => '午餐保护',
    'dinner' => '晚餐保护',
    'fixedRest' => '固定休息',
    'sleep' => '睡眠',
    _ => key,
  };

  static String _hhmm(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';
}

/// 找出 [range] 与睡眠／其它保护窗口中**所有**重叠。
///
/// **纯函数**：不读设置、不看时钟，因此"哪些组合重叠、重叠多少分钟"可以逐条断言。
///
/// **重叠判定按绝对分钟展开**：`LocalTimeRange` 允许跨午夜（睡眠 23:30–08:00 就是），
/// 因此不能直接比 `start`／`end`。这里把每个区间摊成 `[start, end)` 与
/// `[start + 1440, end + 1440)` 两段再求交——跨午夜的窗口因此能与清晨的窗口正确相交。
///
/// [dayKind] 非 `any` 时，只比较"同为该日型或日型为 any"的窗口：
/// 工作日睡眠与周末早餐互不影响。
List<ProtectedTimeOverlap> findProtectedTimeOverlaps({
  required ProtectedTimeKind kind,
  required LocalTimeRange range,
  required List<ProtectedTimeRule> protectedTimes,
  LocalTimeRange? sleepRange,
  DayKind dayKind = DayKind.any,
}) {
  final overlaps = <ProtectedTimeOverlap>[];
  if (sleepRange != null) {
    final hit = _intersect(range, sleepRange);
    if (hit != null) {
      overlaps.add(
        ProtectedTimeOverlap(
          kind: kind.name,
          otherKind: 'sleep',
          thisRange: range,
          otherRange: sleepRange,
          overlapStartMinute: hit.$1,
          overlapEndMinute: hit.$2,
        ),
      );
    }
  }
  for (final rule in protectedTimes) {
    if (!rule.enabled) continue;
    // 自己与自己当然重叠，但那不是冲突。
    if (rule.kind == kind && rule.range.startMinute == range.startMinute) {
      continue;
    }
    if (dayKind != DayKind.any &&
        rule.dayKind != DayKind.any &&
        rule.dayKind != dayKind) {
      continue;
    }
    final hit = _intersect(range, rule.range);
    if (hit == null) continue;
    overlaps.add(
      ProtectedTimeOverlap(
        kind: kind.name,
        otherKind: rule.kind.name,
        thisRange: range,
        otherRange: rule.range,
        overlapStartMinute: hit.$1,
        overlapEndMinute: hit.$2,
      ),
    );
  }
  return overlaps;
}

/// 两个本地区间的交集；不相交返回 `null`。
///
/// ## 为什么不能"把两端取模之后再判交集"
///
/// 跨午夜区间（睡眠 23:30–08:00）必须展开成绝对分钟才能与清晨的窗口求交。第一版把
/// **结果**两端都取了模 1440，于是 `07:30–08:00` 与 `23:30–08:00` 的重叠算成
/// `start=1410, end=0` 的两元组，`overlapMinutes` 得到 30 —— 数值碰巧对，
/// 但"完全落在睡眠内部的早餐"（`07:00–07:30`）算出 `start=1410, end=450`：
/// 取模把两端拆到了不同的日，交集判定直接失效（实测该用例返回空）。
///
/// 正确做法：**在绝对坐标里求交，再把结果整体平移到 `[0, 1440)`**。
/// 平移后跨午夜的重叠自然得到 `end < start`，与 [LocalTimeRange] 的约定一致。
(int, int)? _intersect(LocalTimeRange a, LocalTimeRange b) {
  for (final aStart in [a.startMinute, a.startMinute + _day]) {
    final aEnd = aStart + a.durationMinutes;
    for (final bStart in [b.startMinute, b.startMinute + _day]) {
      final bEnd = bStart + b.durationMinutes;
      final start = aStart > bStart ? aStart : bStart;
      final end = aEnd < bEnd ? aEnd : bEnd;
      if (start >= end) continue;
      return (_normalize(start), _normalize(end));
    }
  }
  return null;
}

const int _day = LocalTimeRange.minutesPerDay;

/// 把绝对分钟整体平移到 `[0, 1440)`。两次相减而不是各自取模——
/// 各自取模会把"跨午夜"这段信息丢掉（见 [_intersect] 的说明）。
int _normalize(int minute) {
  var value = minute;
  while (value >= _day) {
    value -= _day;
  }
  return value;
}
