import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/day_exception_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide DayException;
import 'package:personal_planner/data/repositories/drift_day_exception_repository.dart';
import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

final class _FixedClock implements Clock {
  _FixedClock(this.instant);
  DateTime instant;

  @override
  DateTime nowUtc() => instant;
}

void main() {
  final zones = TimeZoneDatabase();
  late AppDatabase database;
  late DriftDayExceptionRepository repository;
  late MemorySettingsRepository settingsRepository;
  late SettingsService settings;
  late _FixedClock clock;
  late DayExceptionService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftDayExceptionRepository(database);
    settingsRepository = MemorySettingsRepository();
    settings = SettingsService(repository: settingsRepository);
    clock = _FixedClock(DateTime.utc(2026, 10, 17, 12));
    service = DayExceptionService(
      repository: repository,
      settings: settings,
      clock: clock,
      zones: zones,
      timeZoneId: 'Asia/Shanghai',
    );
  });

  tearDown(() => database.close());

  Future<DayException> draft(
    DateTime date, {
    DayExceptionKind kind = DayExceptionKind.temporaryExtensionDay,
    int original = 22 * 60,
    int temporary = 23 * 60,
    int wake = 7 * 60 + 30 + 24 * 60,
    RecoveryChoice recovery = RecoveryChoice.none,
    DateTime? recoveryDate,
  }) => service.createDraft(
    localDate: date,
    kind: kind,
    originalSleepStartOffsetMinutes: original,
    temporarySleepStartOffsetMinutes: temporary,
    fixedWakeOffsetMinutes: wake,
    recoveryChoice: recovery,
    recoveryLocalDate: recoveryDate,
    source: 'test',
  );

  test('草稿不进入逐日策略，确认后才生效', () async {
    final value = await draft(DateTime(2026, 10, 17));
    expect(value.status, DayExceptionStatus.draft);
    expect(value.affectsSchedule, isFalse);
    expect(await service.confirmedForDate(DateTime(2026, 10, 17)), isNull);

    final confirmed = await service.confirm(value);
    expect(confirmed.status, DayExceptionStatus.confirmed);
    expect(
      (await service.confirmedForDate(DateTime(2026, 10, 17)))?.id,
      confirmed.id,
    );
  });

  test('同一本地日再次确认会撤销旧确认记录', () async {
    final first = await service.confirm(await draft(DateTime(2026, 10, 17)));
    final second = await service.confirm(await draft(DateTime(2026, 10, 17)));
    expect(second.id, isNot(first.id));
    final rows = await repository.listBetween(
      DateTime(2026, 10, 17),
      DateTime(2026, 10, 17),
    );
    expect(rows.where((row) => row.status == DayExceptionStatus.confirmed), [
      second,
    ]);
    expect(
      rows.singleWhere((row) => row.id == first.id).status,
      DayExceptionStatus.revoked,
    );
  });

  test('撤销可见、不可再次确认，记录保留', () async {
    final confirmed = await service.confirm(
      await draft(DateTime(2026, 10, 17)),
    );
    clock.instant = DateTime.utc(2026, 10, 18, 1);
    final revoked = await service.revoke(confirmed.id);
    expect(revoked.status, DayExceptionStatus.revoked);
    expect(revoked.revokedAtUtc, clock.instant);
    expect(await service.confirmedForDate(DateTime(2026, 10, 17)), isNull);
    expect(() => service.confirm(revoked), throwsA(isA<Exception>()));
  });

  test('滚动 7 天默认最多 2 次，且禁止连续日', () async {
    expect(await settings.loadWeeklyExtensionQuota(), 2);
    await service.confirm(await draft(DateTime(2026, 10, 17)));
    await service.confirm(await draft(DateTime(2026, 10, 19)));
    expect(await service.remainingExtensionQuota(DateTime(2026, 10, 21)), 0);
    expect(await service.canProposeExtension(DateTime(2026, 10, 20)), isFalse);
    // 10-18 与 10-17 连续，单独命中连续日规则。
    expect(await service.canProposeExtension(DateTime(2026, 10, 18)), isFalse);
    // 窗口继续滚动后 10-17 离开七日窗口。
    expect(await service.canProposeExtension(DateTime(2026, 10, 24)), isTrue);
  });

  test('配额设为 0 时不能提出延长日', () async {
    await settings.saveWeeklyExtensionQuota(0);
    final value = await draft(DateTime(2026, 10, 17));
    await expectLater(
      service.confirm(value),
      throwsA(isA<DayExceptionValidationException>()),
    );
  });

  test('用户主动特殊日不占用延长日配额', () async {
    await service.confirm(
      await draft(
        DateTime(2026, 10, 17),
        kind: DayExceptionKind.userSpecialDay,
      ),
    );
    expect(await service.remainingExtensionQuota(DateTime(2026, 10, 17)), 2);
    expect(await service.canProposeExtension(DateTime(2026, 10, 17)), isTrue);
  });

  test('低于绝对最低睡眠时确认失败且不写库', () async {
    await settings.saveAbsoluteMinimumSleepMinutes(9 * 60);
    final value = await draft(DateTime(2026, 10, 17), temporary: 23 * 60 + 30);
    await expectLater(service.confirm(value), throwsA(isA<ArgumentError>()));
    expect(await service.confirmedForDate(DateTime(2026, 10, 17)), isNull);
  });

  test('同一份计划最多采用一个临时延长日', () async {
    Future<DayException> draftFor(DateTime date) => service.createDraft(
      localDate: date,
      kind: DayExceptionKind.temporaryExtensionDay,
      originalSleepStartOffsetMinutes: 22 * 60,
      temporarySleepStartOffsetMinutes: 23 * 60,
      fixedWakeOffsetMinutes: 7 * 60 + 30 + 24 * 60,
      source: 'test',
      triggeringProposalId: 'proposal-1',
    );
    await service.confirm(await draftFor(DateTime(2026, 10, 17)));
    await expectLater(
      service.confirm(await draftFor(DateTime(2026, 10, 19))),
      throwsA(isA<DayExceptionValidationException>()),
    );
  });

  test('恢复日进入 affectingDate，撤销后一并消失', () async {
    final value = await service.confirm(
      await draft(
        DateTime(2026, 10, 17),
        recovery: RecoveryChoice.nextDayRest,
        recoveryDate: DateTime(2026, 10, 18),
      ),
    );
    expect(
      (await service.affectingDate(DateTime(2026, 10, 18))).single.id,
      value.id,
    );
    await service.revoke(value.id);
    expect(await service.affectingDate(DateTime(2026, 10, 18)), isEmpty);
  });
}
