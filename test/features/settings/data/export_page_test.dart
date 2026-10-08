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

  // ─────────────────────────────────────────────────────────────────────────────
  // M9（路线图 §13 第 3 条）："拒绝访问路径能**恢复**选择"。
  //
  // 上面那条只验到"失败时给出了重新选择的入口、点了也真的再选一次"。
  // **"恢复"的意思是：换一个能写的位置之后这次导出要成**——而那一步此前没有被验过。
  // 只验到"给了按钮"是不够的：按钮点了、位置也换了，但错误还在、或者文件没写成，
  // 用户仍然拿不到导出。
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('M9 被拒绝之后换一个能写的位置，导出真的成功且错误提示消失', (tester) async {
    // 第一次给一个拒绝访问的位置，第二次给一个能写的。
    final files = _FlakyFiles(
      destinations: [
        r'F:\zs200\Documents\planner.json',
        r'G:\exports\planner.json',
      ],
    );
    final service = ExportService(
      source: const _OneFactSource(),
      files: files,
      clock: const _FixedClock(),
    );
    await tester.pumpWidget(MaterialApp(home: ExportPage(service: service)));

    // ① 第一次：写入被拒。
    await tester.tap(find.text('导出完整 JSON'));
    await tester.pumpAndSettle();
    expect(find.text('重新选择保存位置'), findsOneWidget, reason: '第一次失败后必须给出恢复入口');

    // ② 换位置重来：这次必须**成功**。
    await tester.tap(find.text('重新选择保存位置'));
    await tester.pumpAndSettle();

    expect(files.selectionCount, 2, reason: '点"重新选择保存位置"要真的再问一次位置');
    expect(
      find.text('重新选择保存位置'),
      findsNothing,
      reason:
          '这次写成功了，失败提示与恢复入口都应当消失——'
          '否则用户会以为还是没成功，反复点',
    );
    expect(
      find.textContaining('已导出 1 条记录'),
      findsOneWidget,
      reason: '恢复之后必须真的拿到导出结果，而不只是"错误不见了"',
    );
    expect(files.writeAttempts, 2, reason: '应当恰好尝试写两次：第一次被拒、第二次成功');

    // **成功时会把刚选的目标路径显示出来**，这是**对的**，不是泄漏：
    // 那是用户**自己刚在选择器里选的那个位置**，用来确认"写到我指定的地方了"。
    // 失败时才必须脱敏——而失败路径是**结构性**安全的：
    // `ExportWriteException` **不带任何字段**（见 `export_service.dart`），
    // 底层适配器捕获到的那个真实路径**根本传不到界面上**，而不是靠界面记得别打印。
    // 因此这里断言"显示了用户选的那个路径"，把这条有意的区别固定下来。
    expect(
      find.textContaining(r'G:\exports\planner.json'),
      findsOneWidget,
      reason: '成功时给出刚选的目标路径供确认',
    );
    expect(
      find.textContaining(r'F:\zs200\Documents'),
      findsNothing,
      reason: '失败那一次被拒的路径绝不许留在界面上',
    );
  });

  testWidgets('M9 连续两次被拒时仍然停在可恢复状态，不假装成功', (tester) async {
    // 反面：如果换一个位置**还是**写不了，界面必须继续给出恢复入口，
    // 而不是把上一次的失败当成功、也不是把错误吞掉。
    final files = _FlakyFiles(
      destinations: [r'F:\denied\a.json', r'F:\denied\b.json'],
      alwaysDeny: true,
    );
    final service = ExportService(
      source: const _OneFactSource(),
      files: files,
      clock: const _FixedClock(),
    );
    await tester.pumpWidget(MaterialApp(home: ExportPage(service: service)));

    await tester.tap(find.text('导出完整 JSON'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新选择保存位置'));
    await tester.pumpAndSettle();

    expect(find.text('重新选择保存位置'), findsOneWidget, reason: '还能再试');
    expect(
      find.textContaining('已导出'),
      findsNothing,
      reason: '两次都没写成，绝不能显示"已导出"',
    );
    expect(
      find.textContaining('PathAccessException'),
      findsNothing,
      reason: '原始异常仍然不许出现在界面上',
    );
  });
}

/// 按次序返回不同保存位置的替身：用来演"第一次被拒、换一个位置后成功"。
final class _FlakyFiles implements ExportFilePort {
  _FlakyFiles({required this.destinations, this.alwaysDeny = false});

  final List<String> destinations;
  final bool alwaysDeny;

  int selectionCount = 0;
  int writeAttempts = 0;

  @override
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required String extension,
  }) async {
    final index = selectionCount < destinations.length
        ? selectionCount
        : destinations.length - 1;
    selectionCount++;
    return destinations[index];
  }

  @override
  Future<String> writeFile({
    required String destination,
    required Stream<List<int>> bytes,
  }) async {
    writeAttempts++;
    await bytes.drain<void>();
    // 第一次一律拒绝；`alwaysDeny` 时一律拒绝。
    if (alwaysDeny || writeAttempts == 1) {
      throw const ExportWriteException();
    }
    return destination;
  }
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
