import 'package:personal_planner/core/time_zone.dart';

/// 本机时区的解析结果。
final class LocalTimeZoneResolution {
  const LocalTimeZoneResolution({
    required this.timeZoneId,
    required this.exact,
    this.diagnostic,
  });

  final String timeZoneId;

  /// 是否由"当前 UTC 偏移"精确匹配得到。
  ///
  /// false 表示候选表里没有与当前偏移相同的时区，结果只是最接近的近似值，
  /// 调用方应当提示用户手动指定，而不是把它当作正确结果静默使用。
  final bool exact;

  final String? diagnostic;
}

/// 把"本机当前的 UTC 偏移"解析为 IANA 时区标识。
///
/// 需求 §13 要求"以本机当前时区保存和展示"，而此前的实现把 `'Asia/Shanghai'`
/// 写死在调用点，等于假定所有用户都在东八区。
///
/// Dart 没有读取 IANA 标识的 API：`DateTime.timeZoneName` 返回的是缩写或本地化
/// 显示名（如"中国标准时间"），不是 `Asia/Shanghai` 这样的标识；`timeZoneOffset`
/// 只给偏移量。因此这里按当前偏移在一份候选表中定位，并明确区分"精确匹配"与
/// "近似"两种情况。
///
/// **已知局限**：同一偏移可能对应多个时区，而它们的夏令时规则不同（例如 UTC-7
/// 在七月既可能是 `America/Los_Angeles`，也可能是一年四季都为 -7 的
/// `America/Phoenix`）。仅凭偏移无法区分，因此结果按 [candidateIds] 的顺序确定，
/// 用户显式指定的时区（[resolve] 的 `preferred`）始终优先，可用来纠正这种情况。
/// 要彻底解决需要平台能力（Windows 的 `GetDynamicTimeZoneInformation`）或让用户
/// 在首次引导中选择，见 §13.0 的 R11。
final class LocalTimeZoneResolver {
  const LocalTimeZoneResolver(this._zones);

  final TimeZoneDatabase _zones;

  /// 候选时区，按"覆盖常见偏移 + 常见程度"排列。
  ///
  /// 顺序决定同一偏移下的选择结果：越靠前越优先。列表覆盖了整点、半小时与
  /// 45 分钟偏移，使绝大多数机器的偏移都能精确匹配。
  static const List<String> candidateIds = <String>[
    'Europe/London',
    'UTC',
    'Europe/Berlin',
    'Europe/Athens',
    'Europe/Moscow',
    'Atlantic/Azores',
    'Atlantic/Cape_Verde',
    'Africa/Lagos',
    'Africa/Cairo',
    'Africa/Johannesburg',
    'Asia/Jerusalem',
    'Asia/Tehran',
    'Asia/Dubai',
    'Asia/Karachi',
    'Asia/Kolkata',
    'Asia/Kathmandu',
    'Asia/Dhaka',
    'Asia/Yangon',
    'Asia/Bangkok',
    'Asia/Shanghai',
    'Asia/Tokyo',
    'Asia/Seoul',
    'Australia/Perth',
    'Australia/Brisbane',
    'Australia/Adelaide',
    'Australia/Lord_Howe',
    'Australia/Sydney',
    'Pacific/Noumea',
    'Pacific/Auckland',
    'Pacific/Tongatapu',
    'Pacific/Chatham',
    'Asia/Kamchatka',
    'Pacific/Kiritimati',
    'Pacific/Pago_Pago',
    'Pacific/Gambier',
    'Pacific/Honolulu',
    'Pacific/Marquesas',
    'America/Anchorage',
    'America/Los_Angeles',
    'America/Phoenix',
    'America/Denver',
    'America/Chicago',
    'America/New_York',
    'America/Halifax',
    'America/St_Johns',
    'America/Noronha',
    'America/Sao_Paulo',
    'America/Argentina/Buenos_Aires',
  ];

  /// 解析本机时区。
  ///
  /// [localOffset] 取自本机当前时刻的 `DateTime.timeZoneOffset`；
  /// [nowUtc] 用于计算各候选时区在该时刻的偏移（因此夏令时状态会被计入）；
  /// [preferred] 为用户显式指定的时区，优先级最高。
  LocalTimeZoneResolution resolve({
    required Duration localOffset,
    required DateTime nowUtc,
    String? preferred,
  }) {
    if (!nowUtc.isUtc) {
      throw ArgumentError.value(nowUtc, 'nowUtc', 'Must be UTC.');
    }
    final chosen = preferred?.trim();
    if (chosen != null && chosen.isNotEmpty) {
      return LocalTimeZoneResolution(
        timeZoneId: chosen,
        exact: true,
        diagnostic: '用户显式指定',
      );
    }

    for (final id in candidateIds) {
      if (_offsetAt(id, nowUtc) == localOffset) {
        return LocalTimeZoneResolution(timeZoneId: id, exact: true);
      }
    }

    var best = candidateIds.first;
    var bestDelta = _offsetAt(best, nowUtc) == null
        ? null
        : (_offsetAt(best, nowUtc)! - localOffset).abs();
    for (final id in candidateIds.skip(1)) {
      final offset = _offsetAt(id, nowUtc);
      if (offset == null) continue;
      final delta = (offset - localOffset).abs();
      if (bestDelta == null || delta < bestDelta) {
        best = id;
        bestDelta = delta;
      }
    }
    if (bestDelta == null) {
      return const LocalTimeZoneResolution(
        timeZoneId: 'UTC',
        exact: false,
        diagnostic: '候选时区在当前时区库中均不可用，回退到 UTC',
      );
    }
    return LocalTimeZoneResolution(
      timeZoneId: best,
      exact: false,
      diagnostic:
          '候选时区中没有与当前偏移 $localOffset 相同的时区，'
          '已取最接近的 $best（偏差 $bestDelta）',
    );
  }

  /// 候选时区在该时刻的 UTC 偏移；标识在当前时区库中不存在时返回 null。
  ///
  /// 返回 null 而不是抛出：候选表是常量，其中一个标识失效不应让"解析本机时区"
  /// 整个失败——那会让应用在最基础的一步崩溃。
  Duration? _offsetAt(String timeZoneId, DateTime nowUtc) {
    try {
      return _zones.toLocal(nowUtc, timeZoneId).timeZoneOffset;
    } catch (_) {
      return null;
    }
  }
}
