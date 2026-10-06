import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_academic_calendar_repository.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';

final _now = DateTime.utc(2026, 10, 5, 2);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var value = 0;
  @override
  String next() => 'id-${++value}';
}

void main() {
  late AppDatabase database;
  late AcademicCalendarService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    service = AcademicCalendarService(
      repository: DriftAcademicCalendarRepository(database),
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
  });

  tearDown(() => database.close());

  test('保存学期会分配标识和时戳，编辑时保留创建时间', () async {
    final created = await service.saveTerm(
      name: '2026 秋季学期',
      firstWeekMonday: DateTime(2026, 9, 7),
      totalWeeks: 16,
      timeZoneId: 'Asia/Shanghai',
    );
    expect(created.id, 'id-1');
    expect(created.createdAtUtc, _now);

    final edited = await service.saveTerm(
      existing: created,
      name: '秋季学期',
      firstWeekMonday: DateTime(2026, 9, 7),
      totalWeeks: 18,
      timeZoneId: 'Asia/Shanghai',
    );
    expect(edited.id, created.id);
    expect(edited.createdAtUtc, created.createdAtUtc);
    expect(edited.totalWeeks, 18);
  });

  test('服务拒绝非法模板，不产生部分写入', () async {
    await expectLater(
      service.saveTemplate(
        name: '主校区',
        entries: [
          PeriodEntry(periodNumber: 1, startMinute: 480, endMinute: 525),
          PeriodEntry(periodNumber: 1, startMinute: 535, endMinute: 580),
        ],
      ),
      throwsArgumentError,
    );
    expect(await service.listTemplates(), isEmpty);
  });

  test('保存模板并切换默认模板', () async {
    final entries = [
      PeriodEntry(periodNumber: 1, startMinute: 480, endMinute: 525),
    ];
    final first = await service.saveTemplate(
      name: '主校区',
      entries: entries,
      isDefault: true,
    );
    final second = await service.saveTemplate(name: '奉贤', entries: entries);

    await service.setDefaultTemplate(second.id);

    final templates = await service.listTemplates();
    expect(
      templates.singleWhere((item) => item.id == first.id).isDefault,
      false,
    );
    expect(
      templates.singleWhere((item) => item.id == second.id).isDefault,
      true,
    );
  });
}
