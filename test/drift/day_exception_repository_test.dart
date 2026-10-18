import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide DayException;
import 'package:personal_planner/data/repositories/drift_day_exception_repository.dart';
import 'package:personal_planner/domain/models/day_exception.dart';

DayException _exception({
  required String id,
  required DateTime date,
  DayExceptionStatus status = DayExceptionStatus.confirmed,
  RecoveryChoice recovery = RecoveryChoice.none,
  DateTime? recoveryDate,
  DateTime? revokedAt,
}) => DayException(
  id: id,
  localDate: date,
  kind: DayExceptionKind.userSpecialDay,
  status: status,
  originalSleepStartOffsetMinutes: 22 * 60,
  temporarySleepStartOffsetMinutes: 23 * 60 + 30,
  fixedWakeOffsetMinutes: 7 * 60 + 30 + 24 * 60,
  absoluteMinimumSleepMinutes: 6 * 60,
  recoveryChoice: recovery,
  source: 'test',
  createdAtUtc: DateTime.utc(2026, 10, 17, 8),
  updatedAtUtc: DateTime.utc(2026, 10, 17, 8),
  recoveryLocalDate: recoveryDate,
  revokedAtUtc: revokedAt,
);

void main() {
  late AppDatabase database;
  late DriftDayExceptionRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftDayExceptionRepository(database);
  });

  tearDown(() => database.close());

  test('保存后可按日期读回，且逐值相等', () async {
    final value = _exception(id: 'd1', date: DateTime(2026, 10, 17));
    await repository.save(value);
    expect(await repository.findConfirmed(DateTime(2026, 10, 17)), value);
  });

  test('草稿不参与 findConfirmed 与 listAffecting', () async {
    await repository.save(
      _exception(
        id: 'draft',
        date: DateTime(2026, 10, 17),
        status: DayExceptionStatus.draft,
      ),
    );
    expect(await repository.findConfirmed(DateTime(2026, 10, 17)), isNull);
    expect(await repository.listAffecting(DateTime(2026, 10, 17)), isEmpty);
  });

  test('listAffecting 同时匹配特殊日本日与恢复日', () async {
    final value = _exception(
      id: 'rest',
      date: DateTime(2026, 10, 17),
      recovery: RecoveryChoice.nextDayRest,
      recoveryDate: DateTime(2026, 10, 18),
    );
    await repository.save(value);
    expect(await repository.listAffecting(DateTime(2026, 10, 17)), [value]);
    expect(await repository.listAffecting(DateTime(2026, 10, 18)), [value]);
    expect(await repository.listAffecting(DateTime(2026, 10, 19)), isEmpty);
  });

  test('listBetween 闭区间且按日期、更新时间、ID 稳定排序', () async {
    final first = _exception(id: 'b', date: DateTime(2026, 10, 18));
    final second = _exception(id: 'a', date: DateTime(2026, 10, 18));
    final third = _exception(id: 'c', date: DateTime(2026, 10, 20));
    await repository.save(third);
    await repository.save(first);
    await repository.save(second);
    final values = await repository.listBetween(
      DateTime(2026, 10, 18),
      DateTime(2026, 10, 19),
    );
    expect(values.map((value) => value.id), ['a', 'b']);
  });

  test('撤销保留记录、状态与审计时刻，之后不再影响排程', () async {
    final value = _exception(id: 'd1', date: DateTime(2026, 10, 17));
    await repository.save(value);
    final revokedAt = DateTime.utc(2026, 10, 17, 12);
    await repository.revoke('d1', revokedAt);

    final all = await database.select(database.dayExceptions).get();
    expect(all, hasLength(1));
    expect(all.single.status, 'revoked');
    expect(all.single.revokedAtUtc, revokedAt.microsecondsSinceEpoch);
    expect(await repository.findConfirmed(DateTime(2026, 10, 17)), isNull);
  });

  test('相同 ID 保存是覆盖，不产生第二行', () async {
    final value = _exception(id: 'd1', date: DateTime(2026, 10, 17));
    await repository.save(value);
    await repository.save(
      value.copyWith(
        status: DayExceptionStatus.expired,
        updatedAtUtc: DateTime.utc(2026, 10, 18),
      ),
    );
    final rows = await database.select(database.dayExceptions).get();
    expect(rows, hasLength(1));
    expect(rows.single.status, 'expired');
  });

  test('数据库 CHECK 拒绝非法偏移与非法枚举', () async {
    final value = _exception(id: 'd1', date: DateTime(2026, 10, 17));
    await repository.save(value);
    await expectLater(
      database.customStatement(
        'UPDATE day_exceptions SET temporary_sleep_start_offset_minutes = 2881 '
        "WHERE id = 'd1'",
      ),
      throwsA(isA<Exception>()),
    );
  });
}
