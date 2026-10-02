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
      files: const FileSelectorAdapter(),
      clock: _FixedClock(DateTime.utc(2026, 10, 2, 9, 8, 7)),
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('JSON 含格式版本并完整保留所有用户事实数据集', () async {
    final result = await service.exportJson(directory.path);

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
    final result = await service.exportCsv(directory.path);
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

  test('同一时刻重复导出不覆盖已有同名文件', () async {
    final first = await service.exportJson(directory.path);
    final firstFile = File(first.files.single);
    final original = await firstFile.readAsBytes();

    final second = await service.exportJson(directory.path);

    expect(second.files.single, isNot(first.files.single));
    expect(await firstFile.readAsBytes(), original);
  });

  test('取消目录选择不创建文件', () async {
    final result = await service.exportJson(null);

    expect(result.status, ExportStatus.cancelled);
    expect(await directory.list().toList(), isEmpty);
  });

  test('写入失败会删除临时文件', () async {
    const files = FileSelectorAdapter();

    await expectLater(
      files.writeNewFile(
        directory: directory.path,
        preferredName: 'broken.json',
        bytes: Stream<List<int>>.error(StateError('write failed')),
      ),
      throwsStateError,
    );

    expect(
      await directory
          .list()
          .where((item) => item.path.contains('.tmp-'))
          .toList(),
      isEmpty,
    );
  });
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
