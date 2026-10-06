import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/features/settings/data/export_page.dart';

void main() {
  testWidgets('选择保存位置后显示导出数量和文件路径摘要', (tester) async {
    final files = _ChosenDirectoryFiles('G:\\exports');
    final service = ExportService(
      source: const _OneFactSource(),
      files: files,
      clock: const _FixedClock(),
    );
    await tester.pumpWidget(MaterialApp(home: ExportPage(service: service)));

    await tester.tap(find.text('导出完整 JSON'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已导出 1 条记录'), findsOneWidget);
    expect(
      find.textContaining('planner-export-20261002-090807.json'),
      findsOneWidget,
    );
  });

  testWidgets('无法写入时不暴露本机路径并可重新选择', (tester) async {
    final files = _AccessDeniedFiles();
    final service = ExportService(
      source: const _OneFactSource(),
      files: files,
      clock: const _FixedClock(),
    );
    await tester.pumpWidget(MaterialApp(home: ExportPage(service: service)));

    await tester.tap(find.text('导出 CSV'));
    await tester.pumpAndSettle();

    expect(find.textContaining('所选位置'), findsOneWidget);
    expect(find.textContaining('下载'), findsOneWidget);
    expect(find.text('F:\\zs200\\Documents'), findsNothing);
    expect(find.textContaining('PathAccessException'), findsNothing);
    expect(find.text('重新选择保存位置'), findsOneWidget);

    await tester.tap(find.text('重新选择保存位置'));
    await tester.pumpAndSettle();
    expect(files.selectionCount, 2);
  });
}

final class _ChosenDirectoryFiles implements ExportFilePort {
  _ChosenDirectoryFiles(this.directory);
  final String directory;

  @override
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required String extension,
  }) async => '$directory\\$suggestedName';

  @override
  Future<String> writeFile({
    required String destination,
    required Stream<List<int>> bytes,
  }) async {
    await bytes.drain<void>();
    return destination;
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

final class _AccessDeniedFiles implements ExportFilePort {
  var selectionCount = 0;

  @override
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required String extension,
  }) async {
    selectionCount++;
    return 'F:\\zs200\\Documents\\$suggestedName';
  }

  @override
  Future<String> writeFile({
    required String destination,
    required Stream<List<int>> bytes,
  }) async {
    throw const ExportWriteException();
  }
}

final class _FixedClock implements Clock {
  const _FixedClock();

  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 2, 9, 8, 7);
}
