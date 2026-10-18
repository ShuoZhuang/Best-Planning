import 'package:personal_planner/core/time_zone.dart';

/// 特殊日的种类（规范 §8.1）。
enum DayExceptionKind {
  /// 用户主动保存的特殊日。
  userSpecialDay,

  /// 排程在正常放置与修复仍无解后提出、用户显式确认的一次性延长日。
  temporaryExtensionDay,
}

/// 特殊日状态（规范 §8.1）。只有 [confirmed] 且日期匹配时进入逐日策略。
enum DayExceptionStatus { draft, confirmed, revoked, expired }

/// 次日恢复选择（规范 §8.4）。四项必须走四条不同路径。
enum RecoveryChoice {
  nextDayRest,
  nextNightEarlierSleep,
  reduceNextDayLoad,
  none,
}

/// 一次**本地日期事实**：特殊日或临时延长日（规范 §8.1）。
///
/// ## 为什么睡眠时刻是"相对本地日 00:00 的分钟偏移"
///
/// 临时入睡与固定起床都可能落在次日：22:00 延到次日 01:00 是 1320 → 1500，
/// 次日 07:30 的固定起床是 1890。若只存 0–1439 的钟面分钟，再用整数大小猜
/// 跨日关系，就无法区分"当天 01:00"与"次日 01:00"——而这两件事对恢复策略
/// 与容量计算完全相反。
///
/// ## 不变量
///
/// - [localDate] / [recoveryLocalDate] 已归一为 `DateTime(y, m, d)`；
/// - 三个偏移都在 `0..2880`，且 `original <= temporary < fixedWake`；
/// - 恢复选择不是 [RecoveryChoice.none] 时必须给出**次日**的恢复日期；
/// - 撤销状态必须带撤销时刻，其余状态不得带；
/// - 审计时刻必须是 UTC。
final class DayException {
  DayException({
    required this.id,
    required this.localDate,
    required this.kind,
    required this.status,
    required this.originalSleepStartOffsetMinutes,
    required this.temporarySleepStartOffsetMinutes,
    required this.fixedWakeOffsetMinutes,
    required this.absoluteMinimumSleepMinutes,
    required this.recoveryChoice,
    required this.source,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.triggeringProposalId,
    this.recoveryLocalDate,
    this.revokedAtUtc,
    this.auditNote = '',
  }) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', '特殊日必须有稳定 ID');
    }
    if (!_isNormalized(localDate)) {
      throw ArgumentError.value(localDate, 'localDate', '必须是已归一的本地日期');
    }
    _requireOffset(
      originalSleepStartOffsetMinutes,
      'originalSleepStartOffsetMinutes',
    );
    _requireOffset(
      temporarySleepStartOffsetMinutes,
      'temporarySleepStartOffsetMinutes',
    );
    _requireOffset(fixedWakeOffsetMinutes, 'fixedWakeOffsetMinutes');
    if (originalSleepStartOffsetMinutes > temporarySleepStartOffsetMinutes) {
      throw ArgumentError(
        '原睡眠开始（$originalSleepStartOffsetMinutes）不得晚于临时睡眠开始'
        '（$temporarySleepStartOffsetMinutes）',
      );
    }
    if (temporarySleepStartOffsetMinutes >= fixedWakeOffsetMinutes) {
      throw ArgumentError(
        '临时睡眠开始（$temporarySleepStartOffsetMinutes）必须早于固定起床'
        '（$fixedWakeOffsetMinutes）',
      );
    }
    if (absoluteMinimumSleepMinutes < 0 ||
        absoluteMinimumSleepMinutes > 24 * 60) {
      throw ArgumentError.value(
        absoluteMinimumSleepMinutes,
        'absoluteMinimumSleepMinutes',
        '绝对最低睡眠必须在 0..1440 分钟',
      );
    }
    if (!createdAtUtc.isUtc || !updatedAtUtc.isUtc) {
      throw ArgumentError('创建与更新时刻必须是 UTC');
    }
    if (updatedAtUtc.isBefore(createdAtUtc)) {
      throw ArgumentError('更新时间不得早于创建时间');
    }
    if (recoveryChoice == RecoveryChoice.none) {
      if (recoveryLocalDate != null) {
        throw ArgumentError('没有恢复选择时不得保存恢复日期');
      }
    } else {
      final recovery = recoveryLocalDate;
      if (recovery == null || !_isNormalized(recovery)) {
        throw ArgumentError('恢复选择必须带已归一的恢复本地日期');
      }
      if (recovery != nextLocalDate) {
        throw ArgumentError('恢复日期必须是特殊日的下一个本地日');
      }
    }
    if (status == DayExceptionStatus.revoked) {
      if (revokedAtUtc == null || !revokedAtUtc!.isUtc) {
        throw ArgumentError('撤销状态必须带 UTC 撤销时刻');
      }
    } else if (revokedAtUtc != null) {
      throw ArgumentError('只有撤销状态可以带撤销时刻');
    }
  }

  final String id;
  final DateTime localDate;
  final DayExceptionKind kind;
  final DayExceptionStatus status;
  final int originalSleepStartOffsetMinutes;
  final int temporarySleepStartOffsetMinutes;
  final int fixedWakeOffsetMinutes;
  final int absoluteMinimumSleepMinutes;
  final RecoveryChoice recoveryChoice;
  final String source;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final String? triggeringProposalId;
  final DateTime? recoveryLocalDate;
  final DateTime? revokedAtUtc;
  final String auditNote;

  /// 只影响排程的状态：草稿、过期与撤销都不得进入 `DailySchedulingPolicy`。
  bool get affectsSchedule => status == DayExceptionStatus.confirmed;

  /// 该事实是否作用于 [date]（特殊日本日或它的恢复次日）。
  bool affectsLocalDate(DateTime date) {
    final key = normalize(date);
    return localDate == key ||
        (status == DayExceptionStatus.confirmed && recoveryLocalDate == key);
  }

  /// 特殊日的次日本地日期。
  DateTime get nextLocalDate =>
      DateTime(localDate.year, localDate.month, localDate.day + 1);

  /// 原睡眠开始的 UTC 时刻。偏移可超过 1440（次日）。
  DateTime originalSleepStartUtc(TimeZoneDatabase zones, String timeZoneId) =>
      _offsetToUtc(zones, timeZoneId, originalSleepStartOffsetMinutes);

  /// 临时睡眠开始的 UTC 时刻（规范 §8.2 的延长边界用）。
  DateTime temporarySleepStartUtc(TimeZoneDatabase zones, String timeZoneId) =>
      _offsetToUtc(zones, timeZoneId, temporarySleepStartOffsetMinutes);

  /// 固定起床的 UTC 时刻；延长日**不得**推迟它。
  DateTime fixedWakeUtc(TimeZoneDatabase zones, String timeZoneId) =>
      _offsetToUtc(zones, timeZoneId, fixedWakeOffsetMinutes);

  /// 按目标时区解析出的实际睡眠分钟：`fixedWake - temporarySleep`。
  ///
  /// 用真实 UTC 时刻相减，因此夏令时切换日的 23 小时/25 小时自然反映在结果里，
  /// 不会把"墙面上 8 小时"当成"实际 8 小时"。
  int resolvedSleepMinutes(TimeZoneDatabase zones, String timeZoneId) {
    final wake = fixedWakeUtc(zones, timeZoneId);
    final sleep = temporarySleepStartUtc(zones, timeZoneId);
    return wake.difference(sleep).inMinutes;
  }

  /// 实际睡眠是否不低于用户设置的绝对最低线（规范 §8.2/§8.4）。
  bool meetsMinimumSleep(TimeZoneDatabase zones, String timeZoneId) =>
      resolvedSleepMinutes(zones, timeZoneId) >= absoluteMinimumSleepMinutes;

  /// 规范 §8.2 的硬边界：不能突破绝对最低睡眠。
  void requireMinimumSleep(TimeZoneDatabase zones, String timeZoneId) {
    final actual = resolvedSleepMinutes(zones, timeZoneId);
    if (actual < absoluteMinimumSleepMinutes) {
      throw ArgumentError(
        '临时睡眠到固定起床只有 $actual 分钟，低于绝对最低睡眠 '
        '$absoluteMinimumSleepMinutes 分钟',
      );
    }
  }

  DayException copyWith({
    DayExceptionStatus? status,
    String? source,
    DateTime? updatedAtUtc,
    DateTime? revokedAtUtc,
    bool clearRevokedAt = false,
    String? triggeringProposalId,
    RecoveryChoice? recoveryChoice,
    DateTime? recoveryLocalDate,
    bool clearRecoveryLocalDate = false,
    String? auditNote,
  }) => DayException(
    id: id,
    localDate: localDate,
    kind: kind,
    status: status ?? this.status,
    originalSleepStartOffsetMinutes: originalSleepStartOffsetMinutes,
    temporarySleepStartOffsetMinutes: temporarySleepStartOffsetMinutes,
    fixedWakeOffsetMinutes: fixedWakeOffsetMinutes,
    absoluteMinimumSleepMinutes: absoluteMinimumSleepMinutes,
    recoveryChoice: recoveryChoice ?? this.recoveryChoice,
    source: source ?? this.source,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    triggeringProposalId: triggeringProposalId ?? this.triggeringProposalId,
    recoveryLocalDate: clearRecoveryLocalDate
        ? null
        : recoveryLocalDate ?? this.recoveryLocalDate,
    revokedAtUtc: clearRevokedAt ? null : revokedAtUtc ?? this.revokedAtUtc,
    auditNote: auditNote ?? this.auditNote,
  );

  @override
  bool operator ==(Object other) =>
      other is DayException &&
      other.id == id &&
      other.localDate == localDate &&
      other.kind == kind &&
      other.status == status &&
      other.originalSleepStartOffsetMinutes ==
          originalSleepStartOffsetMinutes &&
      other.temporarySleepStartOffsetMinutes ==
          temporarySleepStartOffsetMinutes &&
      other.fixedWakeOffsetMinutes == fixedWakeOffsetMinutes &&
      other.absoluteMinimumSleepMinutes == absoluteMinimumSleepMinutes &&
      other.recoveryChoice == recoveryChoice &&
      other.source == source &&
      other.createdAtUtc == createdAtUtc &&
      other.updatedAtUtc == updatedAtUtc &&
      other.triggeringProposalId == triggeringProposalId &&
      other.recoveryLocalDate == recoveryLocalDate &&
      other.revokedAtUtc == revokedAtUtc &&
      other.auditNote == auditNote;

  @override
  int get hashCode => Object.hashAll([
    id,
    localDate,
    kind,
    status,
    originalSleepStartOffsetMinutes,
    temporarySleepStartOffsetMinutes,
    fixedWakeOffsetMinutes,
    absoluteMinimumSleepMinutes,
    recoveryChoice,
    source,
    createdAtUtc,
    updatedAtUtc,
    triggeringProposalId,
    recoveryLocalDate,
    revokedAtUtc,
    auditNote,
  ]);

  @override
  String toString() =>
      'DayException($id $localDate ${kind.name}/${status.name} '
      'sleep=$originalSleepStartOffsetMinutes→'
      '$temporarySleepStartOffsetMinutes wake=$fixedWakeOffsetMinutes '
      'recovery=${recoveryChoice.name})';

  DateTime _offsetToUtc(
    TimeZoneDatabase zones,
    String timeZoneId,
    int offsetMinutes,
  ) {
    final dayOffset = offsetMinutes ~/ (24 * 60);
    final minuteOfDay = offsetMinutes % (24 * 60);
    return zones.localDateTimeToUtc(
      DateTime(localDate.year, localDate.month, localDate.day + dayOffset),
      minuteOfDay,
      timeZoneId,
    );
  }
}

/// 归一为本地日期（时间部分为 0）。
DateTime normalize(DateTime value) =>
    DateTime(value.year, value.month, value.day);

bool _isNormalized(DateTime value) =>
    value.hour == 0 &&
    value.minute == 0 &&
    value.second == 0 &&
    value.millisecond == 0 &&
    value.microsecond == 0;

void _requireOffset(int value, String name) {
  if (value < 0 || value > 48 * 60) {
    throw ArgumentError.value(value, name, '睡眠偏移必须在 0..2880 分钟');
  }
}

/// `YYYY-MM-DD` 的稳定序列化（数据库中日期列的唯一口径）。
String formatLocalDate(DateTime value) {
  final date = normalize(value);
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

/// 解析 `YYYY-MM-DD`；非法格式抛 [FormatException]，不猜测。
DateTime parseLocalDate(String value) {
  final parts = value.split('-');
  if (parts.length != 3 ||
      parts[0].length != 4 ||
      parts[1].length != 2 ||
      parts[2].length != 2) {
    throw FormatException('本地日期必须是 YYYY-MM-DD：$value');
  }
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) {
    throw FormatException('本地日期必须是 YYYY-MM-DD：$value');
  }
  final date = DateTime(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    throw FormatException('本地日期不是真实日期：$value');
  }
  return date;
}
