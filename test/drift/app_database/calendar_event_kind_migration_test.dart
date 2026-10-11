// 1.8.0（设计规范 §14／计划 Task 7）：`calendar_events.kind` 的迁移必须让**旧行可读**。
//
// `schema_migration_test.dart` 已经钉住"v6→v9 之后 `calendar_events` 只多出 `kind` 一列"，
// 那一条验的是**表结构**。它验不到的是：**旧行的那一列有没有值**。
//
// 这件事有具体的历史：`kind` 用普通的 `ALTER TABLE ... ADD COLUMN kind TEXT` 加上去时，
// **既有行拿到的是 NULL**（列声明里的 `NOT NULL DEFAULT 'fixed'` 对已存在的行不生效），
// 于是用生成的 Dart 代码读那一行会崩：
//
//     Null check operator used on a null value   (app_database.g.dart)
//
// 这个缺陷是**真实发生过**的，而当时的迁移用例全绿 —— 因为它们只比对列名。
// 本文件补的就是那一步：**在 v8 库里写一行真实数据，迁移到 v9，再用生成代码读回来**。
//
// 只比对列名的用例回答不了"读得出来吗"，而用户感受到的恰恰是后者。
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/domain/models/calendar_event.dart'
    show CalendarEventKind;

import 'generated/schema.dart';
import 'generated/schema_v8.dart' as v8;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  /// 时间列在生成的 schema 里是 **int**（微秒），迁移用例沿用同一约定。
  int micros(DateTime value) => value.microsecondsSinceEpoch;

  /// 在 v8 库里写一行 `calendar_events`（v8 还没有 `kind` 列）。
  Future<void> insertV8Event(v8.DatabaseAtV8 old, {required String id}) => old
      .into(old.calendarEvents)
      .insert(
        v8.CalendarEventsCompanion.insert(
          id: id,
          title: '线性代数',
          startAtUtc: micros(DateTime.utc(2026, 9, 7, 1)),
          endAtUtc: micros(DateTime.utc(2026, 9, 7, 2)),
          timeZoneId: 'Asia/Shanghai',
          // v8 里 `created_at_utc` 有列默认值，因此不是 insert 的必填项。
          updatedAtUtc: micros(DateTime.utc(2026, 9, 1)),
        ),
      );

  test('**v8 的旧行迁移到 v9 后，用生成代码读得出来且 kind 为 fixed**', () async {
    final schema = await verifier.schemaAt(8);
    final old = v8.DatabaseAtV8(schema.newConnection());
    await insertV8Event(old, id: 'evt-legacy');
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => DateTime.utc(2026, 10, 12),
    );
    await verifier.migrateAndValidate(db, 9);

    // **这一步是重点**：用生成的类型读，而不是 `customSelect`。
    // 旧行若留下 NULL，这里会抛 `Null check operator used on a null value` ——
    // 而只比对列名的用例对这件事一无所知。
    final rows = await db.select(db.calendarEvents).get();

    expect(rows, hasLength(1), reason: '迁移不该丢行');
    expect(rows.single.title, '线性代数', reason: '旧行的既有字段必须逐值保留');
    expect(
      CalendarEventKind.fromStorage(rows.single.kind),
      CalendarEventKind.fixed,
      reason:
          '规范 §10.1／§14：旧记录迁移后**全部为 fixed**。'
          '若这里抛异常，说明迁移没有给旧行回填默认值',
    );

    await db.close();
    schema.close();
  });

  test('迁移后仍能**写入并读回** protected（新值在旧库升级后可用）', () async {
    // 上一条验旧行；这一条验新值可用。两者缺一都不足以说明"迁移完成"：
    // 只验旧行会漏掉"protected 写不进去"，只验新值会漏掉"旧行读不出来"。
    final schema = await verifier.schemaAt(8);
    final old = v8.DatabaseAtV8(schema.newConnection());
    await insertV8Event(old, id: 'evt-legacy');
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => DateTime.utc(2026, 10, 12),
    );
    await verifier.migrateAndValidate(db, 9);

    await db
        .into(db.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'evt-protected',
            title: '保护时间',
            startAtUtc: micros(DateTime.utc(2026, 10, 12, 4)),
            endAtUtc: micros(DateTime.utc(2026, 10, 12, 5)),
            timeZoneId: 'Asia/Shanghai',
            // 列在库里是 `TEXT`（`text().withDefault(Constant('fixed'))`），
            // 存的是 `CalendarEventKind` 的**存储名**。
            updatedAtUtc: micros(DateTime.utc(2026, 10, 12)),
            kind: const Value('protected'),
          ),
        );

    final protected = await (db.select(
      db.calendarEvents,
    )..where((row) => row.id.equals('evt-protected'))).getSingle();

    expect(
      CalendarEventKind.fromStorage(protected.kind),
      CalendarEventKind.protected,
    );
    expect(
      await (db.select(db.calendarEvents)
            ..where((row) => row.id.equals('evt-legacy')))
          .getSingle()
          .then((row) => CalendarEventKind.fromStorage(row.kind)),
      CalendarEventKind.fixed,
      reason: '新增一行 protected 不该影响旧行的 kind',
    );

    await db.close();
    schema.close();
  });

  test('**空库**建到 v9 时 `kind` 落到列默认值 fixed', () async {
    // 与上面两条不同的一条路径：没有旧行时，DEFAULT 才是唯一的来源。
    // 若有人把 DEFAULT 从列声明里拿掉，这条会失败，而上面两条不会。
    final db = AppDatabase(
      NativeDatabase.memory(),
      now: () => DateTime.utc(2026, 10, 12),
    );

    await db
        .into(db.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'evt-default',
            title: '手建日程',
            startAtUtc: micros(DateTime.utc(2026, 10, 12, 4)),
            endAtUtc: micros(DateTime.utc(2026, 10, 12, 5)),
            timeZoneId: 'Asia/Shanghai',
            updatedAtUtc: micros(DateTime.utc(2026, 10, 12)),
          ),
        );

    final row = await (db.select(
      db.calendarEvents,
    )..where((r) => r.id.equals('evt-default'))).getSingle();

    expect(
      CalendarEventKind.fromStorage(row.kind),
      CalendarEventKind.fixed,
      reason: '不传 kind 时必须落到列默认值 fixed，而不是 NULL',
    );

    await db.close();
  });
}
