import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide AcademicTerm, PeriodTemplate;
import 'package:personal_planner/data/repositories/drift_academic_calendar_repository.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';

void main() {
  late AppDatabase database;
  late DriftAcademicCalendarRepository repository;
  final created = DateTime.utc(2026, 10, 1);
  final updated = DateTime.utc(2026, 10, 5);

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftAcademicCalendarRepository(database);
  });

  tearDown(() => database.close());

  AcademicTerm term() => AcademicTerm(
    id: 'term-1',
    name: '2026 秋季学期',
    firstWeekMonday: DateTime(2026, 9, 7),
    totalWeeks: 16,
    timeZoneId: 'Asia/Shanghai',
    createdAtUtc: created,
    updatedAtUtc: updated,
  );

  PeriodTemplate template({
    required String id,
    required bool isDefault,
    List<PeriodEntry>? entries,
  }) => PeriodTemplate(
    id: id,
    name: '主校区 $id',
    isDefault: isDefault,
    entries:
        entries ??
        [
          PeriodEntry(periodNumber: 1, startMinute: 480, endMinute: 525),
          PeriodEntry(periodNumber: 2, startMinute: 535, endMinute: 580),
        ],
    createdAtUtc: created,
    updatedAtUtc: updated,
  );

  test('学期日期以本地日期往返', () async {
    await repository.saveTerm(term());

    final saved = (await repository.listTerms()).single;
    expect(saved.firstWeekMonday, DateTime(2026, 9, 7));
    expect(saved.totalWeeks, 16);
    expect(saved.timeZoneId, 'Asia/Shanghai');
  });

  test('模板与多行节次原子保存并按节次号读回', () async {
    await repository.saveTemplate(template(id: 'template-1', isDefault: true));

    final saved = (await repository.listTemplates()).single;
    expect(saved.isDefault, isTrue);
    expect(saved.entries.map((entry) => entry.periodNumber), [1, 2]);
  });

  test('替换模板中途失败时旧模板与旧节次完整保留', () async {
    await repository.saveTemplate(template(id: 'template-1', isDefault: true));
    await database.customStatement('''
      CREATE TRIGGER reject_third_period
      BEFORE INSERT ON period_template_entries
      WHEN NEW.period_number = 3
      BEGIN
        SELECT RAISE(ABORT, 'rejected for atomicity test');
      END
    ''');

    await expectLater(
      repository.saveTemplate(
        template(
          id: 'template-1',
          isDefault: false,
          entries: [
            PeriodEntry(periodNumber: 1, startMinute: 600, endMinute: 645),
            PeriodEntry(periodNumber: 3, startMinute: 655, endMinute: 700),
          ],
        ),
      ),
      throwsA(isA<Exception>()),
    );

    final saved = (await repository.listTemplates()).single;
    expect(saved.isDefault, isTrue);
    expect(saved.entries.map((entry) => entry.startMinute), [480, 535]);
  });

  test('设置默认模板会在同一事务中清除之前的默认项', () async {
    await repository.saveTemplate(template(id: 'one', isDefault: true));
    await repository.saveTemplate(template(id: 'two', isDefault: false));

    await repository.setDefaultTemplate('two', updated);

    final templates = await repository.listTemplates();
    expect(
      templates.singleWhere((item) => item.id == 'one').isDefault,
      isFalse,
    );
    expect(templates.singleWhere((item) => item.id == 'two').isDefault, isTrue);
  });
}
