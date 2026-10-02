import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/local_time_zone.dart';
import 'package:personal_planner/core/time_zone.dart';

/// 需求 §13 要求"以本机当前时区保存和展示"。Dart 无法读取 IANA 标识，因此按当前
/// UTC 偏移在候选表中定位。本测试固定该解析的可观察行为，包括它对不确定情形的
/// 处理（同一偏移对应多个时区时只能取候选表中靠前的那个）。
void main() {
  final zones = TimeZoneDatabase();
  final resolver = LocalTimeZoneResolver(zones);
  final winter = DateTime.utc(2026, 1, 15, 12);
  final summer = DateTime.utc(2026, 7, 15, 12);

  LocalTimeZoneResolution at(
    Duration offset, {
    DateTime? when,
    String? preferred,
  }) => resolver.resolve(
    localOffset: offset,
    nowUtc: when ?? winter,
    preferred: preferred,
  );

  test('常见整点偏移解析为对应时区', () {
    expect(at(const Duration(hours: 8)).timeZoneId, 'Asia/Shanghai');
    expect(at(const Duration(hours: 9)).timeZoneId, 'Asia/Tokyo');
    expect(at(const Duration(hours: 14)).timeZoneId, 'Pacific/Kiritimati');
    expect(at(const Duration(hours: -11)).timeZoneId, 'Pacific/Pago_Pago');
    // 零偏移优先给 London（保留夏令时规则），而不是 UTC。
    expect(at(Duration.zero).timeZoneId, 'Europe/London');
  });

  test('半小时与 45 分钟偏移也能精确匹配', () {
    expect(
      at(const Duration(hours: 5, minutes: 30)).timeZoneId,
      'Asia/Kolkata',
    );
    expect(
      at(const Duration(hours: 5, minutes: 45)).timeZoneId,
      'Asia/Kathmandu',
    );
    expect(
      at(const Duration(hours: 6, minutes: 30)).timeZoneId,
      'Asia/Yangon',
    );
    expect(
      at(const Duration(hours: -3, minutes: -30)).timeZoneId,
      'America/St_Johns',
    );
  });

  test('夏令时状态计入偏移匹配', () {
    expect(at(Duration.zero, when: winter).timeZoneId, 'Europe/London');
    expect(at(const Duration(hours: 1), when: summer).timeZoneId, 'Europe/London');
  });

  test('候选表覆盖每个整点偏移（冬夏两季都精确匹配）', () {
    for (final when in [winter, summer]) {
      for (var hours = -11; hours <= 14; hours++) {
        final resolution = at(Duration(hours: hours), when: when);
        expect(
          resolution.exact,
          isTrue,
          reason: '偏移 $hours 小时在 $when 未能精确匹配',
        );
      }
    }
  });

  test('候选表标识全部有效，不会让解析失败', () {
    for (final id in LocalTimeZoneResolver.candidateIds) {
      expect(
        () => zones.location(id),
        returnsNormally,
        reason: '候选时区 $id 在当前时区库中不存在',
      );
    }
  });

  test('候选表无同偏移时标记为近似而不是谎报精确', () {
    final approximate = at(const Duration(hours: 3, minutes: 17));

    expect(approximate.exact, isFalse);
    expect(approximate.diagnostic, isNotNull);
    expect(approximate.timeZoneId, isNotEmpty);
  });

  test('用户显式指定优先于偏移匹配', () {
    final preferred = at(
      const Duration(hours: 8),
      preferred: 'America/New_York',
    );

    expect(preferred.timeZoneId, 'America/New_York');
    expect(preferred.exact, isTrue);
    expect(preferred.diagnostic, '用户显式指定');
    // 空白指定视为未指定。
    expect(at(const Duration(hours: 8), preferred: '   ').timeZoneId, 'Asia/Shanghai');
  });

  test('非 UTC 的参照时刻被拒绝', () {
    expect(
      () => resolver.resolve(
        localOffset: Duration.zero,
        nowUtc: DateTime(2026, 1, 15, 12),
      ),
      throwsArgumentError,
    );
  });
}
