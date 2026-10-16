import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/platform/files/backup_archive_adapter.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:drift/native.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent, RecurrenceRule;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/calendar_event_edit.dart';

void main() {
  late Directory workspace;
  late File databaseFile;
  late _FileDatabaseLifecycle database;
  late BackupService service;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('planner-backup-test-');
    databaseFile = File(
      '${workspace.path}${Platform.pathSeparator}planner.sqlite',
    );
    _createDatabase(databaseFile.path, marker: 'original');
    database = _FileDatabaseLifecycle(databaseFile.path);
    service = BackupService(
      database: database,
      archives: const BackupArchiveAdapter(),
      hashes: const Sha256FileHashAdapter(),
      clock: const _FixedClock(),
      appVersion: '1.0.0',
      settingsJson: () async => '{"theme":"system"}',
    );
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('包含任务、计划和计时的数据库可完整备份并恢复', () async {
    final backup = '${workspace.path}${Platform.pathSeparator}backup.zip';
    final manifest = await service.create(backup);
    _replaceMarker(databaseFile.path, 'changed');

    final validated = await service.validate(backup);
    await service.restore(backup);

    expect(manifest.schemaVersion, 1);
    expect(validated.sha256, manifest.sha256);
    final restored = sqlite3.open(databaseFile.path);
    addTearDown(restored.close);
    expect(restored.userVersion, 1);
    expect(
      restored.select('SELECT title FROM tasks').single['title'],
      'original',
    );
    expect(restored.select('SELECT id FROM plan_versions'), hasLength(1));
    expect(restored.select('SELECT id FROM time_entries'), hasLength(1));
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 10 Step 2（课程与保护时间管理修复计划）：**备份往返**
  //
  // 备份是**整文件字节复制**，因此它天然保留一切——这条用例的价值不在于"发现
  // 备份会丢数据"，而在于把**本批次新增的那些形状**钉进往返里：
  // 多片段课程、改名后的重复保护时间、逐次例外、早餐规则。它们恰好是
  // "如果备份改成按表导出就会先坏掉"的那部分。
  // ─────────────────────────────────────────────────────────────────────────────
  test('**多片段课程、保护时间例外与早餐设置都能往返**', () async {
    // **这一条用自己的库文件**：`setUp` 里那个是为了测"备份/恢复的校验路径"而手写的
    // 最小 v1 库（只有 tasks/plan_versions/time_entries 三张表）。拿它当起点，
    // drift 会按 user_version=1 去跑迁移，而 `areas` 之类的表根本不存在——
    // 那报的是夹具的错，与本批次要守的兼容性无关。
    final path = '${workspace.path}${Platform.pathSeparator}real.sqlite';
    final backup = '${workspace.path}${Platform.pathSeparator}courses.zip';

    // ① 由 drift 自己建库（当前 schema），再灌入本批次的数据形状。
    final seeding = AppDatabase(NativeDatabase(File(path)));
    await _seedCourseAndProtection(seeding);
    await seeding.close();

    final before = _snapshot(path);
    expect(before['schemaVersion'], 10, reason: '前置条件：v10 只扩充批次状态的 CHECK');
    expect(
      (before['events']! as List),
      isNotEmpty,
      reason: '前置条件：夹具必须真的灌进了数据，否则这条用例是空转',
    );

    // ② 备份 → 破坏原库 → 恢复。
    final roundTrip = BackupService(
      database: _FileDatabaseLifecycle(path, version: 10),
      archives: const BackupArchiveAdapter(),
      hashes: const Sha256FileHashAdapter(),
      clock: const _FixedClock(),
      appVersion: '1.0.0',
      settingsJson: () async => '{}',
    );
    final manifest = await roundTrip.create(backup);
    _replaceMarker(path, 'wiped');
    await roundTrip.restore(backup);

    // ③ 逐项比对：课程身份、锚点、规则、例外、资料字段、早餐。
    expect(
      _snapshot(path),
      before,
      reason:
          '备份往返必须逐项保持。**逐项**而不是"文件大小一致"：'
          '大小相同而内容错位是最难被发现的一种损坏',
    );
    expect(manifest.schemaVersion, before['schemaVersion']);
  });

  test('错误哈希、截断数据库、新 schema 和路径穿越全部被拒绝且原库不变', () async {
    final original = await databaseFile.readAsBytes();
    final valid = '${workspace.path}${Platform.pathSeparator}valid.zip';
    await service.create(valid);

    final cases = <String, Future<String> Function()>{
      'hashMismatch': () => _tamperManifest(valid, workspace, (manifest) {
        manifest['sha256'] = List.filled(32, '00').join();
      }),
      'truncatedSqlite': () => _archiveWithDatabase(
        workspace,
        name: 'truncated.zip',
        databaseBytes: utf8.encode('not a sqlite database'),
        schemaVersion: 1,
      ),
      'newerSchema': () async {
        final newer = File(
          '${workspace.path}${Platform.pathSeparator}newer.sqlite',
        );
        _createDatabase(newer.path, marker: 'future', schemaVersion: 99);
        return _archiveWithDatabase(
          workspace,
          name: 'newer.zip',
          databaseBytes: await newer.readAsBytes(),
          schemaVersion: 99,
        );
      },
      'pathTraversal': () => _withTraversalEntry(valid, workspace),
    };

    for (final entry in cases.entries) {
      final path = await entry.value();
      await expectLater(
        service.restore(path),
        throwsA(isA<BackupValidationException>()),
        reason: entry.key,
      );
      expect(await databaseFile.readAsBytes(), original, reason: entry.key);
    }
    expect(
      await workspace
          .list()
          .where((item) => item.path.contains('planner-restore-'))
          .toList(),
      isEmpty,
    );
  });
}

void _createDatabase(
  String path, {
  required String marker,
  int schemaVersion = 1,
}) {
  final db = sqlite3.open(path);
  db.execute('PRAGMA user_version = $schemaVersion');
  db.execute('CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL)');
  db.execute('CREATE TABLE plan_versions (id TEXT PRIMARY KEY)');
  db.execute('CREATE TABLE time_entries (id TEXT PRIMARY KEY)');
  db.execute('INSERT INTO tasks VALUES (?, ?)', ['task-1', marker]);
  db.execute("INSERT INTO plan_versions VALUES ('plan-1')");
  db.execute("INSERT INTO time_entries VALUES ('entry-1')");
  db.close();
}

void _replaceMarker(String path, String marker) {
  final db = sqlite3.open(path);
  db.execute('UPDATE tasks SET title = ?', [marker]);
  db.close();
}

/// 灌入本批次的数据形状：多片段课程、逐次例外、重复保护时间、早餐规则。
Future<void> _seedCourseAndProtection(AppDatabase app) async {
  final calendar = DriftCalendarRepository(app, zones: TimeZoneDatabase());
  const zoneId = 'Asia/Shanghai';

  // ① **一门课的两个片段**（单周一条、双周一条）——"整个课程"要按两个锚点一起改。
  for (final (eventId, ruleId, weekdays, interval) in const [
    ('evt-calc-odd', 'rule-calc-odd', {DateTime.monday}, 2),
    ('evt-calc-even', 'rule-calc-even', {DateTime.wednesday}, 2),
  ]) {
    await calendar.saveRecurring(
      CalendarEvent(
        id: eventId,
        title: '高等数学(上)',
        startAtUtc: DateTime.utc(2026, 9, 7, 0),
        endAtUtc: DateTime.utc(2026, 9, 7, 0, 45),
        timeZoneId: zoneId,
        recurrenceRuleId: ruleId,
        sourceKind: CalendarEventSourceKind.timetableImport,
        logicalCourseId: 'course-calc',
        location: 'D206',
        // **教师存在 `notes` 列**（计划 Global Constraints）。
        notes: '赵敏',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: ruleId,
        weekdays: weekdays,
        localStartMinute: 8 * 60,
        durationMinutes: 45,
        intervalWeeks: interval,
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
        timeZoneId: zoneId,
      ),
    );
  }

  // ② **同名但不同 `logicalCourseId`** 的另一门课：它绝不能被改到。
  await calendar.saveRecurring(
    CalendarEvent(
      id: 'evt-calc-b',
      title: '高等数学(上)',
      startAtUtc: DateTime.utc(2026, 9, 7, 0),
      endAtUtc: DateTime.utc(2026, 9, 7, 0, 45),
      timeZoneId: zoneId,
      recurrenceRuleId: 'rule-calc-b',
      sourceKind: CalendarEventSourceKind.timetableImport,
      logicalCourseId: 'course-calc-b',
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    ),
    RecurrenceRule(
      id: 'rule-calc-b',
      weekdays: const {DateTime.tuesday},
      localStartMinute: 10 * 60,
      durationMinutes: 45,
      validFromLocalDate: DateTime(2026, 9, 7),
      validUntilLocalDate: DateTime(2026, 12, 20),
      timeZoneId: zoneId,
    ),
  );

  // ③ **一条改名后的重复保护时间** ＋ 它名下的一条逐次例外。
  await calendar.saveRecurring(
    CalendarEvent(
      id: 'protected-gym',
      title: '游泳',
      startAtUtc: DateTime.utc(2026, 10, 6, 6),
      endAtUtc: DateTime.utc(2026, 10, 6, 7),
      timeZoneId: zoneId,
      recurrenceRuleId: 'rule-gym',
      kind: CalendarEventKind.protected,
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    ),
    RecurrenceRule(
      id: 'rule-gym',
      weekdays: const {DateTime.tuesday},
      localStartMinute: 14 * 60,
      durationMinutes: 60,
      validFromLocalDate: DateTime(2026, 10, 6),
      validUntilLocalDate: DateTime(2026, 12, 20),
      timeZoneId: zoneId,
    ),
  );
  await calendar.replaceOccurrence(
    anchorId: 'protected-gym',
    occurrenceStartUtc: DateTime.utc(2026, 10, 20, 6),
    patch: CalendarEventPatch(
      title: '体检',
      notes: '带化验单',
      startAtUtc: DateTime.utc(2026, 10, 20, 8),
      endAtUtc: DateTime.utc(2026, 10, 20, 9),
    ),
    exceptionId: 'exc-checkup',
    updatedAtUtc: DateTime.utc(2026, 10, 1),
  );

  // ④ **早餐规则**（写进设置 JSON）。
  await app
      .into(app.settings)
      .insertOnConflictUpdate(
        SettingsCompanion.insert(
          key: 'planning.rules.v1',
          jsonValue: jsonEncode({
            'protectedTimes': [
              {
                'kind': 'breakfast',
                'startMinute': 450,
                'endMinute': 480,
                'enabled': true,
                'dayKind': 'any',
              },
            ],
          }),
          updatedAtUtc: DateTime.utc(2026, 10, 12).microsecondsSinceEpoch,
        ),
      );
}

/// 把与兼容性有关的行**逐项**读成一张可比较的快照。
///
/// **按列显式列出**而不是 `SELECT *`：本批次新增的列（`kind`、`logical_course_id`）
/// 恰恰是要守的东西，而 `SELECT *` 在"列被删掉"时只会少一项、不会失败。
Map<String, Object?> _snapshot(String path) {
  final db = sqlite3.open(path);
  try {
    final events = db.select(
      'SELECT id, title, kind, notes, location, logical_course_id, '
      'recurrence_rule_id, exception_of_id, start_at_utc, end_at_utc '
      'FROM calendar_events ORDER BY id',
    );
    final rules = db.select(
      'SELECT id, weekdays_mask, local_start_minute, duration_minutes, '
      'interval_weeks, valid_from_local_date, valid_until_local_date, time_zone_id '
      'FROM recurrence_rules ORDER BY id',
    );
    final settings = db.select(
      'SELECT key, json_value FROM settings ORDER BY key',
    );
    return {
      'schemaVersion': db.userVersion,
      'events': [for (final row in events) Map<String, Object?>.from(row)],
      'rules': [for (final row in rules) Map<String, Object?>.from(row)],
      'settings': [for (final row in settings) Map<String, Object?>.from(row)],
    };
  } finally {
    db.close();
  }
}

Future<String> _tamperManifest(
  String source,
  Directory workspace,
  void Function(Map<String, Object?> manifest) change,
) async {
  final archive = ZipDecoder().decodeBytes(await File(source).readAsBytes());
  final output = Archive();
  for (final file in archive) {
    final bytes = file.readBytes() ?? const <int>[];
    if (file.name == 'manifest.json') {
      final manifest = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      change(manifest);
      output.addFile(
        ArchiveFile.bytes(file.name, utf8.encode(jsonEncode(manifest))),
      );
    } else {
      output.addFile(ArchiveFile.bytes(file.name, bytes));
    }
  }
  final path = '${workspace.path}${Platform.pathSeparator}bad-hash.zip';
  await File(path).writeAsBytes(ZipEncoder().encodeBytes(output));
  return path;
}

Future<String> _archiveWithDatabase(
  Directory workspace, {
  required String name,
  required List<int> databaseBytes,
  required int schemaVersion,
}) async {
  final hash = sha256.convert(databaseBytes).toString();
  final manifest = {
    'formatVersion': 1,
    'schemaVersion': schemaVersion,
    'appVersion': '1.0.0',
    'createdAtUtc': '2026-10-02T09:00:00.000Z',
    'databaseLength': databaseBytes.length,
    'sha256': hash,
  };
  final archive = Archive()
    ..addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)))
    ..addFile(ArchiveFile.bytes('planner.sqlite', databaseBytes))
    ..addFile(ArchiveFile.string('exports/settings.json', '{}'));
  final path = '${workspace.path}${Platform.pathSeparator}$name';
  await File(path).writeAsBytes(ZipEncoder().encodeBytes(archive));
  return path;
}

Future<String> _withTraversalEntry(String source, Directory workspace) async {
  final archive = ZipDecoder().decodeBytes(await File(source).readAsBytes())
    ..addFile(ArchiveFile.bytes('../escape.txt', [1]));
  final path = '${workspace.path}${Platform.pathSeparator}traversal.zip';
  await File(path).writeAsBytes(ZipEncoder().encodeBytes(archive));
  return path;
}

final class _FileDatabaseLifecycle implements DatabaseLifecyclePort {
  _FileDatabaseLifecycle(this.path, {this.version = 1});
  final String path;

  /// 这个库"能读"的 schema 版本。
  ///
  /// **默认 1 是刻意的**：`setUp` 里那几个用例造的就是最小 v1 库，而
  /// `newerSchema` 那条拒绝路径正是靠 `manifest.schemaVersion > 这里` 触发的。
  /// 真实 schema（v9）那条往返路径必须显式传 9——否则一份刚由 v9 库导出的备份
  /// 会被判成"来自更新的版本"，而那报的是夹具的错。
  final int version;

  @override
  int get supportedSchemaVersion => version;

  @override
  Future<void> createConsistentSnapshot(String destination) async {
    await File(path).copy(destination);
  }

  @override
  Future<DatabaseInspection> inspect(String candidate) async {
    Database? db;
    try {
      db = sqlite3.open(candidate, mode: OpenMode.readOnly);
      final result = db.select('PRAGMA integrity_check').single.values.single;
      return DatabaseInspection(
        schemaVersion: db.userVersion,
        integrityOk: result == 'ok',
      );
    } catch (_) {
      return const DatabaseInspection(schemaVersion: -1, integrityOk: false);
    } finally {
      db?.close();
    }
  }

  @override
  Future<void> replaceWith(String validatedDatabase) async {
    await File(validatedDatabase).copy(path);
  }

  @override
  Future<void> eraseAll() async => File(path).writeAsBytes(const []);
}

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 2, 9);
}
