import 'dart:convert';

import 'package:personal_planner/core/clock.dart';

abstract interface class ExportDataSource {
  Future<Map<String, List<Map<String, Object?>>>> loadAllFacts();
}

abstract interface class ExportFilePort {
  Future<String?> chooseDirectory();

  Future<String> writeNewFile({
    required String directory,
    required String preferredName,
    required Stream<List<int>> bytes,
  });
}

enum ExportStatus { completed, cancelled }

final class ExportResult {
  const ExportResult._({
    required this.status,
    required this.files,
    required this.recordCount,
  });

  const ExportResult.completed({
    required List<String> files,
    required int recordCount,
  }) : this._(
         status: ExportStatus.completed,
         files: files,
         recordCount: recordCount,
       );

  const ExportResult.cancelled()
    : this._(status: ExportStatus.cancelled, files: const [], recordCount: 0);

  final ExportStatus status;
  final List<String> files;
  final int recordCount;
}

final class ExportService {
  const ExportService({
    required this.source,
    required this.files,
    required this.clock,
  });

  final ExportDataSource source;
  final ExportFilePort files;
  final Clock clock;

  Future<ExportResult> exportJson(String? directory) async {
    if (directory == null) return const ExportResult.cancelled();
    final facts = await source.loadAllFacts();
    final path = await files.writeNewFile(
      directory: directory,
      preferredName: '${_fileStem()}.json',
      bytes: _jsonBytes(facts),
    );
    return ExportResult.completed(
      files: [path],
      recordCount: _recordCount(facts),
    );
  }

  Future<ExportResult> exportCsv(String? directory) async {
    if (directory == null) return const ExportResult.cancelled();
    final facts = await source.loadAllFacts();
    final path = await files.writeNewFile(
      directory: directory,
      preferredName: '${_fileStem()}.csv',
      bytes: _csvBytes(facts),
    );
    return ExportResult.completed(
      files: [path],
      recordCount: _recordCount(facts),
    );
  }

  String _fileStem() {
    final value = clock.nowUtc();
    String two(int number) => number.toString().padLeft(2, '0');
    return 'planner-export-${value.year}${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }

  Stream<List<int>> _jsonBytes(
    Map<String, List<Map<String, Object?>>> facts,
  ) async* {
    final encoder = const JsonEncoder();
    yield utf8.encode(
      '{"schemaVersion":1,"exportedAtUtc":'
      '${encoder.convert(clock.nowUtc().toIso8601String())},"tables":{',
    );
    var firstTable = true;
    for (final entry in facts.entries) {
      if (!firstTable) yield const [0x2c];
      firstTable = false;
      yield utf8.encode('${encoder.convert(entry.key)}:[');
      for (var index = 0; index < entry.value.length; index++) {
        if (index > 0) yield const [0x2c];
        yield utf8.encode(encoder.convert(entry.value[index]));
      }
      yield const [0x5d];
    }
    yield utf8.encode('}}');
  }

  Stream<List<int>> _csvBytes(
    Map<String, List<Map<String, Object?>>> facts,
  ) async* {
    yield const [0xEF, 0xBB, 0xBF];
    const columns = [
      'dataset',
      'record_id',
      'task_id',
      'title',
      'notes',
      'planned_start_utc',
      'planned_end_utc',
      'actual_start_utc',
      'actual_end_utc',
      'estimated_minutes',
      'actual_minutes',
      'data_json',
    ];
    yield utf8.encode('${columns.join(',')}\r\n');
    for (final entry in facts.entries) {
      for (final record in entry.value) {
        final isPlanned = entry.key == 'scheduleBlocks';
        final isActual = entry.key == 'timeEntries';
        final actualMinutes = isActual ? _actualMinutes(record) : null;
        final values = <Object?>[
          entry.key,
          record['id'] ?? record['key'],
          record['taskId'],
          record['title'],
          record['notes'],
          if (isPlanned) _instant(record['startAtUtc']) else null,
          if (isPlanned) _instant(record['endAtUtc']) else null,
          if (isActual) _instant(record['startedAtUtc']) else null,
          if (isActual) _instant(record['endedAtUtc']) else null,
          record['estimatedMinutes'],
          actualMinutes,
          jsonEncode(record),
        ];
        yield utf8.encode('${values.map(_csvCell).join(',')}\r\n');
      }
    }
  }

  static int _recordCount(Map<String, List<Map<String, Object?>>> facts) =>
      facts.values.fold(0, (total, records) => total + records.length);

  static String? _instant(Object? microseconds) {
    if (microseconds is! int) return null;
    return DateTime.fromMicrosecondsSinceEpoch(
      microseconds,
      isUtc: true,
    ).toIso8601String();
  }

  static int? _actualMinutes(Map<String, Object?> record) {
    final start = record['startedAtUtc'];
    final end = record['endedAtUtc'];
    if (start is! int || end is! int) return null;
    final paused = record['pausedMinutes'] as int? ?? 0;
    return ((end - start) ~/ Duration.microsecondsPerMinute) - paused;
  }

  static String _csvCell(Object? value) {
    if (value == null) return '';
    final text = value.toString();
    if (!text.contains(RegExp('[,"\\r\\n]'))) return text;
    return '"${text.replaceAll('"', '""')}"';
  }
}
