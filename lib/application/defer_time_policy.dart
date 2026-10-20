import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/time_range.dart';

/// 延后量的校验结果（计划 Task 4 Step 2）。
///
/// 用结果对象而不是抛异常：0、负数、241 分钟、73 小时、8 天都是**用户输入**，
/// 不是程序错误；界面需要拿到"为什么不行"的稳定码而不是捕获异常。
final class DeferAmountValidation {
  const DeferAmountValidation._({
    required this.isValid,
    required this.normalizedAmount,
    this.reasonCode,
    this.minAmount = 1,
    this.maxAmount = 0,
  });

  const DeferAmountValidation.valid(int amount, {int min = 1, int max = 0})
    : this._(
        isValid: true,
        normalizedAmount: amount,
        minAmount: min,
        maxAmount: max,
      );

  const DeferAmountValidation.invalid(String reasonCode)
    : this._(isValid: false, normalizedAmount: null, reasonCode: reasonCode);

  final bool isValid;

  /// 通过校验后的**原值**（分钟粒度对齐发生在按目标日计算下界时，不在这里）。
  final int? normalizedAmount;

  /// 稳定原因码：`amountNotPositive` / `amountOutOfRange` /
  /// `longerThanOneWeek`（最后一条对应"超过 7 个本地日请改任务时间范围"）。
  final String? reasonCode;

  final int minAmount;
  final int maxAmount;
}

/// 「延后本次」的唯一时间策略（计划 Task 4）。
///
/// **三条职责，只有一处执行**：
/// 1. 范围：分钟 1–240、小时 1–72、天 1–7（超过 7 天属于改任务计划边界）；
/// 2. 下界：分钟/小时按**绝对经过时长**算，天按**本地日历日**且保持本地钟面；
/// 3. 粒度：按**目标所在本地日**的实际粒度向上对齐，不沿用源日、不用固定 5 分钟。
///
/// 修复前的缺陷是 DFR-019/022/023：界面允许 72 小时/365 天，下界固定按 5 分钟对齐，
/// DST 解析散落在各层。把它们收进一个纯类之后，生成、预览、确认看到的是同一个下界。
final class DeferTimePolicy {
  const DeferTimePolicy(this.zones);

  final TimeZoneDatabase zones;

  /// 天单位的硬上限（DFR-019）。超过它不是"再挪一点"，而是改任务时间范围。
  static const int maxDays = 7;
  static const int maxHours = 72;
  static const int maxMinutes = 240;

  DeferAmountValidation validateAmount(int amount, DeferUnit unit) {
    if (amount <= 0) {
      return const DeferAmountValidation.invalid('amountNotPositive');
    }
    return switch (unit) {
      DeferUnit.minutes => amount <= maxMinutes
          ? DeferAmountValidation.valid(
              amount,
              max: maxMinutes,
            )
          : const DeferAmountValidation.invalid('amountOutOfRange'),
      DeferUnit.hours => amount <= maxHours
          ? DeferAmountValidation.valid(amount, max: maxHours)
          : const DeferAmountValidation.invalid('amountOutOfRange'),
      DeferUnit.days => amount <= maxDays
          ? DeferAmountValidation.valid(amount, max: maxDays)
          : const DeferAmountValidation.invalid('longerThanOneWeek'),
    };
  }

  /// 计算延后的**下界** `notBeforeUtc`（半开区间的起点）。
  ///
  /// [granularityForDate] 接收**目标本地日期**（只含年月日）并返回该日粒度分钟数。
  /// 之所以是函数而不是常量：学习/周末/特殊日本来就可能用不同粒度（DFR-022）。
  DateTime computeNotBefore({
    required DateTime sourceStartUtc,
    required int amount,
    required DeferUnit unit,
    required String timeZoneId,
    required int Function(DateTime normalizedLocalDate) granularityForDate,
  }) {
    final validation = validateAmount(amount, unit);
    if (!validation.isValid) {
      throw ArgumentError.value(
        amount,
        'amount',
        '非法的延后量（${validation.reasonCode}）',
      );
    }
    if (!sourceStartUtc.isUtc) {
      throw ArgumentError.value(sourceStartUtc, 'sourceStartUtc', 'Must be UTC.');
    }
    final raw = switch (unit) {
      DeferUnit.minutes => sourceStartUtc.add(Duration(minutes: amount)),
      DeferUnit.hours => sourceStartUtc.add(Duration(hours: amount)),
      DeferUnit.days => _addLocalDays(
        sourceStartUtc: sourceStartUtc,
        days: amount,
        timeZoneId: timeZoneId,
      ),
    };
    return _alignUpToGrid(raw, timeZoneId, granularityForDate);
  }

  /// 延后操作的专属有效窗口终点（计划 §「规划范围」）。
  ///
  /// `max(默认窗口终点, endOfLocalDay(notBeforeLocalDate + 1 day))`：
  /// 最多 7 个本地日的延后必须落在一个能完整容纳它的窗口里，否则"合法目标"
  /// 会在装配层被截掉，表现为莫名其妙的无解。
  DateTime adjustmentWindowEnd({
    required DateTime notBeforeUtc,
    required DateTime defaultWindowEnd,
    required String timeZoneId,
  }) {
    final local = zones.toLocal(notBeforeUtc, timeZoneId);
    final nextLocalDate = DateTime(local.year, local.month, local.day + 1);
    final endOfNextDay = zones.localMidnightToUtc(
      DateTime(nextLocalDate.year, nextLocalDate.month, nextLocalDate.day + 1),
      timeZoneId,
    );
    return endOfNextDay.isAfter(defaultWindowEnd) ? endOfNextDay : defaultWindowEnd;
  }

  /// 目标本地日期（只含年月日）。用于按日查粒度与展示"最早可开始"。
  DateTime targetLocalDate({
    required DateTime sourceStartUtc,
    required int amount,
    required DeferUnit unit,
    required String timeZoneId,
  }) {
    final notBefore = computeNotBefore(
      sourceStartUtc: sourceStartUtc,
      amount: amount,
      unit: unit,
      timeZoneId: timeZoneId,
      granularityForDate: (_) => 1,
    );
    final local = zones.toLocal(notBefore, timeZoneId);
    return DateTime(local.year, local.month, local.day);
  }

  DateTime _addLocalDays({
    required DateTime sourceStartUtc,
    required int days,
    required String timeZoneId,
  }) {
    final local = zones.toLocal(sourceStartUtc, timeZoneId);
    return zones.resolveLocalWallTime(
      localDate: DateTime(local.year, local.month, local.day + days),
      minuteOfDay: local.hour * 60 + local.minute,
      timeZoneId: timeZoneId,
    );
  }

  /// 按**目标所在本地日**的粒度向上对齐（DFR-022）。
  ///
  /// 跨日进位时在新的一天重新解析并继续对齐；每一轮都必须让 UTC 严格增加，
  /// 否则 DST 缺失/重复日会退化成原地循环。
  DateTime _alignUpToGrid(
    DateTime instantUtc,
    String timeZoneId,
    int Function(DateTime normalizedLocalDate) granularityForDate,
  ) {
    var candidate = instantUtc;
    for (var guard = 0; guard < 4; guard++) {
      final local = zones.toLocal(candidate, timeZoneId);
      final localDate = DateTime(local.year, local.month, local.day);
      final grid = granularityForDate(localDate);
      if (grid <= 1) return candidate;
      final minutesFromMidnight = local.hour * 60 + local.minute;
      final withinGrid = minutesFromMidnight % grid;
      final hasSubMinute =
          local.second != 0 ||
          local.millisecond != 0 ||
          local.microsecond != 0;
      if (withinGrid == 0 && !hasSubMinute) return candidate;

      final addMinutes = withinGrid == 0 ? grid : grid - withinGrid;
      var targetMinute = minutesFromMidnight + addMinutes;
      var targetDate = localDate;
      while (targetMinute >= 24 * 60) {
        targetMinute -= 24 * 60;
        targetDate = DateTime(targetDate.year, targetDate.month, targetDate.day + 1);
      }
      final aligned = zones.resolveLocalWallTime(
        localDate: targetDate,
        minuteOfDay: targetMinute,
        timeZoneId: timeZoneId,
      );
      if (!aligned.isAfter(candidate)) {
        // DST 缺失把对齐结果压回同一时刻：直接推进到下一个网格点（在下一轮重新查粒度）。
        candidate = candidate.add(Duration(minutes: grid));
        continue;
      }
      candidate = aligned;
    }
    return candidate;
  }
}

extension DeferUnitRangeX on DeferUnit {
  /// 该单位的绝对上限；界面据此显示"1～N"。
  int get maxAmount => switch (this) {
    DeferUnit.minutes => DeferTimePolicy.maxMinutes,
    DeferUnit.hours => DeferTimePolicy.maxHours,
    DeferUnit.days => DeferTimePolicy.maxDays,
  };

  String get unitLabel => switch (this) {
    DeferUnit.minutes => '分钟',
    DeferUnit.hours => '小时',
    DeferUnit.days => '天',
  };
}

/// 延后下界与源区间的关系（供预览展示"原时间 → 最早可开始时间"）。
TimeRange deferBoundPreview({
  required DateTime sourceStartUtc,
  required DateTime notBeforeUtc,
  required int durationMinutes,
}) => TimeRange(
  startUtc: notBeforeUtc,
  endUtc: notBeforeUtc.add(Duration(minutes: durationMinutes)),
);
