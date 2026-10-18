import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/day_exception.dart';

DayException _day({
  String id = 'day-1',
  DateTime? localDate,
  DayExceptionStatus status = DayExceptionStatus.confirmed,
  int original = 22 * 60,
  int temporary = 22 * 60,
  int wake = 1890,
  RecoveryChoice recoveryChoice = RecoveryChoice.none,
  DateTime? recoveryLocalDate,
  DateTime? revokedAtUtc,
  int minimumSleep = 6 * 60,
}) {
  final date = localDate ?? DateTime(2026, 10, 17);
  return DayException(
    id: id,
    localDate: date,
    kind: DayExceptionKind.userSpecialDay,
    status: status,
    originalSleepStartOffsetMinutes: original,
    temporarySleepStartOffsetMinutes: temporary,
    fixedWakeOffsetMinutes: wake,
    absoluteMinimumSleepMinutes: minimumSleep,
    recoveryChoice: recoveryChoice,
    source: 'test',
    createdAtUtc: DateTime.utc(2026, 10, 17, 9),
    updatedAtUtc: DateTime.utc(2026, 10, 17, 9),
    recoveryLocalDate: recoveryLocalDate,
    revokedAtUtc: revokedAtUtc,
  );
}

void main() {
  final zones = TimeZoneDatabase();

  group('DayException 不变量', () {
    test('本地日期必须是已归一日期', () {
      expect(
        () => _day(localDate: DateTime(2026, 10, 17, 8)),
        throwsArgumentError,
      );
    });

    test('偏移必须在 0..2880 且保持跨日顺序', () {
      expect(() => _day(original: -1), throwsArgumentError);
      expect(() => _day(wake: 2881), throwsArgumentError);
      expect(() => _day(original: 1400, temporary: 1390), throwsArgumentError);
      expect(() => _day(temporary: 1890, wake: 1890), throwsArgumentError);
    });

    test('22:00 延到次日 01:00、07:30 起床是合法的有序事实', () {
      final value = _day(original: 1320, temporary: 1500, wake: 1890);
      expect(value.temporarySleepStartOffsetMinutes, 1500);
      expect(value.fixedWakeOffsetMinutes, 1890);
      expect(value.resolvedSleepMinutes(zones, 'Asia/Shanghai'), 390);
    });

    test('月末与年末的次日偏移不会被当成当月/当年', () {
      final monthEnd = _day(
        localDate: DateTime(2026, 10, 31),
        original: 1320,
        temporary: 1500,
        wake: 1890,
      );
      final wake = monthEnd.fixedWakeUtc(zones, 'Asia/Shanghai');
      expect(wake, DateTime.utc(2026, 10, 31, 23, 30));

      final yearEnd = _day(
        localDate: DateTime(2026, 12, 31),
        original: 1320,
        temporary: 1500,
        wake: 1890,
      );
      expect(
        yearEnd.fixedWakeUtc(zones, 'Asia/Shanghai'),
        DateTime.utc(2026, 12, 31, 23, 30),
      );
    });
    test('实际睡眠按 UTC 时刻相减，夏令时切换日不会被当成固定 9.5 小时', () {
      // 2026-03-08 美东春季拨快：02:00 -> 03:00，22:00 到 07:30 只有 8.5 小时。
      final spring = _day(
        localDate: DateTime(2026, 3, 7),
        original: 1320,
        temporary: 1320,
        wake: 1890,
      );
      expect(spring.resolvedSleepMinutes(zones, 'America/New_York'), 510);
    });

    test('绝对最低睡眠不足时 requireMinimumSleep 抛错', () {
      final value = _day(original: 1320, temporary: 1620, wake: 1890);
      expect(
        () => value.requireMinimumSleep(zones, 'Asia/Shanghai'),
        throwsArgumentError,
      );
    });

    test('恢复选择必须带次日恢复日期，且不得带同日日期', () {
      expect(
        () => _day(recoveryChoice: RecoveryChoice.nextDayRest),
        throwsArgumentError,
      );
      expect(
        () => _day(
          recoveryChoice: RecoveryChoice.nextDayRest,
          recoveryLocalDate: DateTime(2026, 10, 18),
        ),
        returnsNormally,
      );
      expect(
        () => _day(
          recoveryChoice: RecoveryChoice.nextDayRest,
          recoveryLocalDate: DateTime(2026, 10, 19),
        ),
        throwsArgumentError,
      );
      expect(
        () => _day(
          recoveryChoice: RecoveryChoice.none,
          recoveryLocalDate: DateTime(2026, 10, 18),
        ),
        throwsArgumentError,
      );
    });

    test('撤销状态必须带撤销时刻，其它状态不得带', () {
      expect(
        () => _day(status: DayExceptionStatus.revoked),
        throwsArgumentError,
      );
      expect(
        () => _day(
          status: DayExceptionStatus.revoked,
          revokedAtUtc: DateTime.now().toUtc(),
        ),
        returnsNormally,
      );
      expect(
        () => _day(revokedAtUtc: DateTime.now().toUtc()),
        throwsArgumentError,
      );
    });

    test('只有 confirmed 影响排程；恢复日也算影响', () {
      final draft = _day(status: DayExceptionStatus.draft);
      expect(draft.affectsSchedule, isFalse);
      final confirmed = _day(
        recoveryChoice: RecoveryChoice.nextDayRest,
        recoveryLocalDate: DateTime(2026, 10, 18),
      );
      expect(confirmed.affectsSchedule, isTrue);
      expect(confirmed.affectsLocalDate(DateTime(2026, 10, 17)), isTrue);
      expect(confirmed.affectsLocalDate(DateTime(2026, 10, 18)), isTrue);
      expect(confirmed.affectsLocalDate(DateTime(2026, 10, 19)), isFalse);
    });
  });

  group('本地日期序列化', () {
    test('格式化补零并可往返', () {
      expect(formatLocalDate(DateTime(2026, 1, 5)), '2026-01-05');
      expect(parseLocalDate('2026-01-05'), DateTime(2026, 1, 5));
    });

    test('非法日期抛 FormatException，不猜测', () {
      expect(() => parseLocalDate('2026-02-30'), throwsFormatException);
      expect(() => parseLocalDate('2026/01/05'), throwsFormatException);
      expect(() => parseLocalDate('2026-1-5'), throwsFormatException);
    });
  });
}
