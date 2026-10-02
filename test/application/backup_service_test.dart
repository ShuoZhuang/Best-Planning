import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/platform/files/backup_archive_adapter.dart';
import 'package:sqlite3/sqlite3.dart';

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
  _FileDatabaseLifecycle(this.path);
  final String path;

  @override
  int get supportedSchemaVersion => 1;

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
