import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/features/settings/data/export_page.dart';

void main() {
  testWidgets('选择目录后显示导出数量和文件路径摘要', (tester) async {
    final files = _ChosenDirectoryFiles('G:\\exports');
    final service = ExportService(
      source: const _OneFactSource(),
      files: files,
      clock: const _FixedClock(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ExportPage(service: service, files: files),
      ),
    );

    await tester.tap(find.text('导出完整 JSON'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已导出 1 条记录'), findsOneWidget);
    expect(
      find.textContaining('planner-export-20261002-090807.json'),
      findsOneWidget,
    );
  });
}

final class _ChosenDirectoryFiles implements ExportFilePort {
  _ChosenDirectoryFiles(this.directory);
  final String directory;

  @override
  Future<String?> chooseDirectory() async => directory;

  @override
  Future<String> writeNewFile({
    required String directory,
    required String preferredName,
    required Stream<List<int>> bytes,
  }) async {
    await bytes.drain<void>();
    return '$directory\\$preferredName';
  }
}

final class _OneFactSource implements ExportDataSource {
  const _OneFactSource();

  @override
  Future<Map<String, List<Map<String, Object?>>>> loadAllFacts() async => {
    'tasks': [
      {'id': 'task-1', 'title': '论文'},
    ],
  };
}

final class _FixedClock implements Clock {
  const _FixedClock();

  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 2, 9, 8, 7);
}
