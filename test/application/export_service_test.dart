import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/platform/files/file_selector_adapter.dart';

void main() {
  late Directory directory;
  late ExportService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('planner-export-test-');
    service = ExportService(
      source: _FactSource(_facts),
      files: _SavingFilePort(directory),
      clock: _FixedClock(DateTime.utc(2026, 10, 2, 9, 8, 7)),
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('JSON 含格式版本并完整保留所有用户事实数据集', () async {
    final result = await service.exportJson();

    expect(result.status, ExportStatus.completed);
    expect(
      result.recordCount,
      _facts.values.fold(0, (sum, rows) => sum + rows.length),
    );
    final decoded = jsonDecode(
      await File(result.files.single).readAsString(),
    ) as Map<String, Object?>;
    expect(decoded['schemaVersion'], 1);
    expect(decoded['exportedAtUtc'], '2026-10-02T09:08:07.000Z');
    final tables = decoded['tables'] as Map<String, Object?>;
    expect(tables.keys.toSet(), _facts.keys.toSet());
    expect(tables['tasks'], _facts['tasks']);
    expect(tables['settings'], _facts['settings']);
  });

  test('CSV 使用 UTF-8 BOM 且计划和实际时间列明确分开', () async {
    final result = await service.exportCsv();
    final bytes = await File(result.files.single).readAsBytes();

    expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
    final content = utf8.decode(bytes.skip(3).toList());
    expect(content, startsWith('dataset,record_id,task_id'));
    expect(content, contains('planned_start_utc'));
    expect(content, contains('planned_end_utc'));
    expect(content, contains('actual_start_utc'));
    expect(content, contains('actual_end_utc'));
    expect(content, contains('2026-10-02T10:00:00.000Z'));
    expect(content, contains('2026-10-02T10:05:00.000Z'));
  });

  test('导出时请求带默认文件名的标准另存为位置', () async {
    final files = _SavingFilePort(directory);
    final selectingService = ExportService(
      source: _FactSource(_facts),
      files: files,
      clock: _FixedClock(DateTime.utc(2026, 10, 2, 9, 8, 7)),
    );

    await selectingService.exportJson();
    await selectingService.exportCsv();

    expect(files.suggestedNames, [
      'planner-export-20261002-090807.json',
      'planner-export-20261002-090807.csv',
    ]);
    expect(files.extensions, ['json', 'csv']);
  });

  test('取消保存位置选择不创建文件', () async {
    final cancelledService = ExportService(
      source: _FactSource(_facts),
      files: const _CancelledFilePort(),
      clock: _FixedClock(DateTime.utc(2026, 10, 2, 9, 8, 7)),
    );

    final result = await cancelledService.exportJson();

    expect(result.status, ExportStatus.cancelled);
    expect(await directory.list().toList(), isEmpty);
  });

  test('写入失败不会留下未完成的目标文件', () async {
    const files = FileSelectorAdapter();
    final destination = '${directory.path}${Platform.pathSeparator}broken.json';

    await expectLater(
      files.writeFile(
        destination: destination,
        bytes: Stream<List<int>>.error(StateError('write failed')),
      ),
      throwsStateError,
    );

    expect(await File(destination).exists(), isFalse);
  });

  test('文件适配器只在用户选定的最终路径创建文件', () async {
    const files = FileSelectorAdapter();
    final destination = '${directory.path}${Platform.pathSeparator}export.csv';

    final written = await files.writeFile(
      destination: destination,
      bytes: Stream<List<int>>.value(utf8.encode('a,b\r\n1,2')),
    );

    expect(written, destination);
    expect(await File(destination).readAsString(), 'a,b\r\n1,2');
    expect(
      await directory
          .list()
          .where((item) => item.path.contains('.tmp-'))
          .toList(),
      isEmpty,
    );
  });

  test('目标位置拒绝写入时只向上层返回脱敏错误', () async {
    const files = FileSelectorAdapter();
    final destination =
        '${directory.path}${Platform.pathSeparator}missing'
        '${Platform.pathSeparator}private.csv';

    await expectLater(
      files.writeFile(
        destination: destination,
        bytes: Stream<List<int>>.value(utf8.encode('private')),
      ),
      throwsA(isA<ExportWriteException>()),
    );
  });
}

final class _SavingFilePort implements ExportFilePort {
  _SavingFilePort(this.directory);

  final Directory directory;
  final List<String> suggestedNames = [];
  final List<String> extensions = [];

  @override
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required String extension,
  }) async {
    suggestedNames.add(suggestedName);
    extensions.add(extension);
    return '${directory.path}${Platform.pathSeparator}$suggestedName';
  }

  @override
  Future<String> writeFile({
    required String destination,
    required Stream<List<int>> bytes,
  }) async {
    final sink = File(destination).openWrite();
    await sink.addStream(bytes);
    await sink.close();
    return destination;
  }
}

final class _CancelledFilePort implements ExportFilePort {
  const _CancelledFilePort();

  @override
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required String extension,
  }) async => null;

  @override
  Future<String> writeFile({
    required String destination,
    required Stream<List<int>> bytes,
  }) => throw StateError('cancelled export must not write');
}

final _facts = <String, List<Map<String, Object?>>>{
  'areas': [
    {'id': 'area-1', 'name': '学习'},
  ],
  'projects': [
    {'id': 'project-1', 'areaId': 'area-1', 'name': '课程'},
  ],
  'tasks': [
    {'id': 'task-1', 'title': '论文', 'notes': '第一版', 'estimatedMinutes': 90},
  ],
  'recurrenceRules': <Map<String, Object?>>[],
  'calendarEvents': <Map<String, Object?>>[],
  'energyWindows': <Map<String, Object?>>[],
  'settings': [
    {'key': 'planning.userRules.v1', 'jsonValue': '{}'},
  ],
  'planVersions': [
    {'id': 'plan-1', 'status': 'confirmed'},
  ],
  'scheduleBlocks': [
    {
      'id': 'block-1',
      'taskId': 'task-1',
      'startAtUtc': DateTime.utc(2026, 10, 2, 10).microsecondsSinceEpoch,
      'endAtUtc': DateTime.utc(2026, 10, 2, 11).microsecondsSinceEpoch,
    },
  ],
  'timeEntries': [
    {
      'id': 'entry-1',
      'taskId': 'task-1',
      'startedAtUtc': DateTime.utc(2026, 10, 2, 10, 5).microsecondsSinceEpoch,
      'endedAtUtc': DateTime.utc(2026, 10, 2, 10, 55).microsecondsSinceEpoch,
    },
  ],
  'preferenceEvidence': <Map<String, Object?>>[],
  'preferenceRules': <Map<String, Object?>>[],
  'changeLog': <Map<String, Object?>>[],
};

final class _FactSource implements ExportDataSource {
  const _FactSource(this.value);
  final Map<String, List<Map<String, Object?>>> value;

  @override
  Future<Map<String, List<Map<String, Object?>>>> loadAllFacts() async => value;
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;

  @override
  DateTime nowUtc() => value;
}
