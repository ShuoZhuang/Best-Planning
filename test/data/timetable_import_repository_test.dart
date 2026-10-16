import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_timetable_import_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart' as domain;
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';

void main() {
  late AppDatabase database;
  late DriftTimetableImportRepository repository;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftTimetableImportRepository(database);
    await database.customInsert('''
      INSERT INTO areas
        (id, name, color, sort_order, is_life, created_at_utc, updated_at_utc)
      VALUES ('area-study', '学业', 17, 0, 0, 1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO academic_terms
        (id, name, first_week_monday_local_date, total_weeks, time_zone_id,
         created_at_utc, updated_at_utc)
      VALUES ('term', '秋季学期', '2026-09-07', 16, 'Asia/Shanghai', 1, 1)
    ''');
  });

  tearDown(() => database.close());

  test(
    'commit atomically creates one batch with locked imported series',
    () async {
      final batch = await repository.commit(timetableTestCommit());

      expect(batch.createdEventCount, 1);
      expect(
        await database.select(database.timetableImportBatches).get(),
        hasLength(1),
      );
      final events = await database.select(database.calendarEvents).get();
      expect(events, hasLength(1));
      expect(events.single.locked, isTrue);
      expect(events.single.sourceKind, 'timetableImport');
      expect(events.single.importBatchId, batch.id);
      expect(
        await database.select(database.recurrenceRules).get(),
        hasLength(1),
      );
    },
  );

  test(
    'commit rolls back all rows when a later event violates a foreign key',
    () async {
      final valid = _series('event-1', 'rule-1');
      final invalid = _series('event-2', 'rule-2').copyWith(
        event: _series(
          'event-2',
          'rule-2',
        ).event.copyWith(areaId: 'missing-area'),
      );

      await expectLater(
        repository.commit(timetableTestCommit(series: [valid, invalid])),
        throwsA(isA<Exception>()),
      );

      expect(
        await database.select(database.timetableImportBatches).get(),
        isEmpty,
      );
      expect(await database.select(database.calendarEvents).get(), isEmpty);
      expect(await database.select(database.recurrenceRules).get(), isEmpty);
    },
  );

  test('same image hash and term is surfaced as a duplicate batch', () async {
    await repository.commit(timetableTestCommit());

    await expectLater(
      repository.commit(timetableTestCommit(batchId: 'batch-2')),
      throwsA(isA<DuplicateTimetableImportException>()),
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Task 9（课程编辑完整性修复计划 §3.4）：**只有 committed 拦截同图重导入**
  // ───────────────────────────────────────────────────────────────────────────

  group('同图重导入的拦截范围（R1–R4）', () {
    /// 把某个批次改成指定状态。
    Future<void> setStatus(String batchId, String status) =>
        database.customStatement(
          "UPDATE timetable_import_batches SET status = '$status' "
          "WHERE id = '$batchId'",
        );

    test('R2：partiallyDeleted 不拦截——用户正是要用原图把删掉的课补回来', () async {
      await repository.commit(timetableTestCommit());
      await setStatus('batch-1', 'partiallyDeleted');

      final restored = await repository.commit(
        timetableTestCommit(batchId: 'batch-2', idSuffix: '-2'),
      );

      expect(restored.id, 'batch-2');
      expect(restored.status, TimetableImportBatchStatus.committed);
      expect(
        await database.select(database.timetableImportBatches).get(),
        hasLength(2),
        reason: '旧批次必须保留：它的审计记录与"已删除部分课程"的事实还要用',
      );
    });

    test('R3：rolledBack 不拦截', () async {
      await repository.commit(timetableTestCommit());
      await setStatus('batch-1', 'rolledBack');

      final again = await repository.commit(
        timetableTestCommit(batchId: 'batch-2', idSuffix: '-2'),
      );

      expect(again.status, TimetableImportBatchStatus.committed);
    });

    test('draft 也不是"完整导入"，不拦截', () async {
      await database.customStatement('''
        INSERT INTO timetable_import_batches
          (id, term_id, source_image_hash, source_file_name, status,
           created_event_count, created_at_utc, updated_at_utc)
        VALUES ('batch-draft', 'term', 'sha256:test', 'schedule.png', 'draft',
                0, 1, 1)
      ''');

      final committed = await repository.commit(timetableTestCommit());

      expect(committed.id, 'batch-1');
    });

    test('R4：同一连接上的两次同图提交只有一个成功', () async {
      // **判定在事务里**（Task 9 Step 1）：两次提交并发发起时，后一个必须看到
      // 前一个已经写下的批次。事务外的检查会让两者都通过，于是同一张课表入库两遍。
      final results = await Future.wait([
        repository
            .commit(timetableTestCommit(batchId: 'batch-a'))
            .then<Object?>((value) => value)
            .catchError((Object error) => error),
        repository
            .commit(timetableTestCommit(batchId: 'batch-b'))
            .then<Object?>((value) => value)
            .catchError((Object error) => error),
      ]);

      final successes = results.whereType<TimetableImportBatch>().toList();
      final duplicates = results
          .whereType<DuplicateTimetableImportException>()
          .toList();
      expect(successes, hasLength(1), reason: '两个提交不能同时写入同一张完整课表');
      expect(duplicates, hasLength(1));
      expect(
        await database.select(database.timetableImportBatches).get(),
        hasLength(1),
      );
    });

    test('未知状态值不会被当成 committed 之外的任何东西悄悄放过', () {
      expect(
        () => TimetableImportBatchStatus.fromStorage('nonsense'),
        throwsA(isA<UnknownTimetableImportBatchStatusException>()),
        reason:
            '回落成 committed 会把读不懂的批次当成完整导入，永久拦住同图重导入；'
            '回落成别的值又会让它被当成"可以重导"',
      );
      expect(
        TimetableImportBatchStatus.fromStorage('partiallyDeleted'),
        TimetableImportBatchStatus.partiallyDeleted,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Task 10（计划 §2.6）：**持久导入记录的读模型**（H1、H4）
  // ───────────────────────────────────────────────────────────────────────────

  group('导入记录列表（H1、H4）', () {
    test('三种状态各出一行，按创建时间倒序，内部 id 不出现在文案字段里', () async {
      await repository.commit(
        TimetableImportCommit(
          batchId: 'batch-a',
          termId: 'term',
          sourceImageHash: 'sha256:a',
          sourceFileName: 'a.png',
          createdAtUtc: DateTime.utc(2026, 10, 1),
          series: [_series('event-a', 'rule-a')],
        ),
      );
      await repository.commit(
        TimetableImportCommit(
          batchId: 'batch-b',
          termId: 'term',
          sourceImageHash: 'sha256:b',
          sourceFileName: 'b.png',
          createdAtUtc: DateTime.utc(2026, 10, 3),
          series: [_series('event-b', 'rule-b')],
        ),
      );
      await repository.rollback('batch-a');

      // 第三个批次：部分删除（把 status 直接写成删除事务会写的那个值）。
      await repository.commit(
        TimetableImportCommit(
          batchId: 'batch-c',
          termId: 'term',
          sourceImageHash: 'sha256:c',
          sourceFileName: 'c.png',
          createdAtUtc: DateTime.utc(2026, 10, 2),
          series: [_series('event-c', 'rule-c')],
        ),
      );
      await database.customStatement(
        "UPDATE timetable_import_batches SET status = 'partiallyDeleted' "
        "WHERE id = 'batch-c'",
      );

      final items = await repository.listHistory();

      expect(items.map((item) => item.batchId).toList(), [
        'batch-b',
        'batch-c',
        'batch-a',
      ], reason: '按 createdAtUtc 降序；时间相同时按 batch id 保证确定性');
      final byId = {for (final item in items) item.batchId: item};
      expect(byId['batch-b']!.status, TimetableImportBatchStatus.committed);
      expect(byId['batch-b']!.canRollback, isTrue);
      expect(byId['batch-b']!.createdSeriesCount, 1);
      expect(byId['batch-b']!.remainingSeriesCount, 1);
      expect(
        byId['batch-c']!.status,
        TimetableImportBatchStatus.partiallyDeleted,
      );
      expect(byId['batch-c']!.canRollback, isTrue, reason: '还有剩余系列时可以撤销');
      expect(byId['batch-a']!.status, TimetableImportBatchStatus.rolledBack);
      expect(
        byId['batch-a']!.canRollback,
        isFalse,
        reason: 'H4：已撤销的行可见但不可再次撤销',
      );
      // 学期名称来自学期表，而不是把 id 直接念给用户。
      expect(byId['batch-b']!.termName, '秋季学期');
      // 源文件名只有文件名，没有绝对路径。
      expect(byId['batch-b']!.sourceFileName, 'a.png'.replaceAll('a', 'b'));
    });

    test('受保护课程 ⇒ 需要二次确认；一条不剩的 partiallyDeleted 不可撤销', () async {
      await repository.commit(timetableTestCommit());
      // 把锚点改成"被用户修改过"：`updated_at_utc` 不再是批次的创建时间。
      await database.customStatement(
        'UPDATE calendar_events SET updated_at_utc = 99 '
        "WHERE id = 'event-1'",
      );

      var items = await repository.listHistory();
      expect(items.single.protectedSeriesCount, 1);
      expect(items.single.requiresForceConfirmation, isTrue);
      expect(items.single.canRollback, isTrue);

      // 删掉最后一组课程之后：状态是"已删除部分课程"，没有可撤销的东西。
      await database.customStatement(
        "DELETE FROM calendar_events WHERE exception_of_id = 'event-1'",
      );
      await database.customStatement(
        "DELETE FROM calendar_events WHERE id = 'event-1'",
      );
      await database.customStatement(
        "UPDATE timetable_import_batches SET status = 'partiallyDeleted' "
        "WHERE id = 'batch-1'",
      );

      items = await repository.listHistory();
      expect(items.single.remainingSeriesCount, 0);
      expect(items.single.canRollback, isFalse);
      expect(items.single.status, TimetableImportBatchStatus.partiallyDeleted);
    });

    test('includeRolledBack=false 时不列出已撤销的批次', () async {
      await repository.commit(timetableTestCommit());
      await repository.rollback('batch-1');

      expect(await repository.listHistory(), hasLength(1));
      expect(await repository.listHistory(includeRolledBack: false), isEmpty);
    });
  });

  test(
    'conflicting occurrence exclusion is stored atomically with the batch',
    () async {
      final series = _series('event-1', 'rule-1').copyWith(
        exclusions: [
          TimetableImportExclusion(
            id: 'exception-1',
            occurrenceStartUtc: DateTime.utc(2026, 9, 14),
          ),
        ],
      );

      await repository.commit(timetableTestCommit(series: [series]));

      final rows = await database.select(database.calendarEvents).get();
      expect(rows, hasLength(2));
      final exception = rows.singleWhere((row) => row.id == 'exception-1');
      expect(exception.exceptionOfId, 'event-1');
      expect(exception.startAtUtc, exception.endAtUtc);
      expect(exception.importBatchId, 'batch-1');
      expect(
        (await repository.inspectRollback('batch-1')).protectedEventIds,
        isEmpty,
      );

      await repository.rollback('batch-1');
      expect(await database.select(database.calendarEvents).get(), isEmpty);
    },
  );
}

TimetableImportCommit timetableTestCommit({
  String batchId = 'batch-1',
  List<TimetableImportSeriesWrite>? series,

  /// 重导入时锚点与规则的 id 是**新生成的**：复用同一批 id 会撞上主键约束，
  /// 而那条失败报的是"夹具坏了"，不是"重导入被拦住"。
  String idSuffix = '',
}) => TimetableImportCommit(
  batchId: batchId,
  termId: 'term',
  sourceImageHash: 'sha256:test',
  sourceFileName: r'G:\private\schedule.png',
  createdAtUtc: DateTime.utc(2026, 10, 5),
  series: series ?? [_series('event-1$idSuffix', 'rule-1$idSuffix')],
);

TimetableImportSeriesWrite _series(String eventId, String ruleId) {
  final start = DateTime.utc(2026, 9, 7);
  return TimetableImportSeriesWrite(
    event: domain.CalendarEvent(
      id: eventId,
      title: '大学物理',
      startAtUtc: start,
      endAtUtc: start.add(const Duration(minutes: 100)),
      timeZoneId: 'Asia/Shanghai',
      recurrenceRuleId: ruleId,
      areaId: 'area-study',
      sourceKind: domain.CalendarEventSourceKind.timetableImport,
      importBatchId: 'batch-1',
      logicalCourseId: 'course-physics',
      updatedAtUtc: DateTime.utc(2026, 10, 5),
    ),
    rule: domain.RecurrenceRule(
      id: ruleId,
      weekdays: const {DateTime.monday},
      localStartMinute: 8 * 60,
      durationMinutes: 100,
      validFromLocalDate: DateTime(2026, 9, 7),
      validUntilLocalDate: DateTime(2026, 12, 21),
      timeZoneId: 'Asia/Shanghai',
    ),
  );
}
