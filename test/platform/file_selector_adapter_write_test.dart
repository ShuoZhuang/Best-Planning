// 导出的**真实写入路径**必须被跑到。
//
// 这条用例存在的理由：导出服务的测试一直用替身实现 `ExportFilePort`，而真正写文件的
// `FileSelectorAdapter.writeFile` 从未在任何测试里执行过。它曾经把暂存文件放在
// `Directory.systemTemp` 下——在临时目录被锁住的机器上（Dart 在
// `C:\Users\<user>\AppData\Local\Temp` 下建文件返回 errno 5，工作区内正常），
// **暂存先于目标路径失败**，于是用户换到任何一个位置都只看到"没有权限"。
//
// 因此这里只替身"选路径"这一步（真实实现要弹系统对话框），写入走真实实现，
// 并且刻意**不使用 `Directory.systemTemp`**——否则用例会以和产品同样的方式失败。
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/platform/files/file_selector_adapter.dart';

final class _Facts implements ExportDataSource {
  @override
  Future<Map<String, List<Map<String, Object?>>>> loadAllFacts() async => {
    'tasks': [
      {'id': 'task-1', 'title': '写方案'},
    ],
  };
}

/// 只固定"用户选定的路径"，写入仍交给真实端口。
final class _FixedDestination implements ExportFilePort {
  const _FixedDestination({required this.destination, required this.writer});

  final String destination;
  final ExportFilePort writer;

  @override
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required String extension,
  }) async => destination;

  @override
  Future<String> writeFile({
    required String destination,
    required Stream<List<int>> bytes,
  }) => writer.writeFile(destination: destination, bytes: bytes);
}

/// 只记录对话框收到了什么，不真的弹窗。
final class _RecordingSaveDialog extends FileSelectorPlatform {
  String? initialDirectory;
  String? suggestedName;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    initialDirectory = options.initialDirectory;
    suggestedName = options.suggestedName;
    return const FileSaveLocation(r'G:\somewhere\out.json');
  }
}

void main() {
  late Directory workspace;

  setUp(() {
    // 刻意落在工程目录内（.dart_tool 已被忽略），不碰 %TEMP%。
    workspace = Directory(
      '.dart_tool/export-write-test-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  ExportService serviceWritingTo(String destination) => ExportService(
    source: _Facts(),
    files: _FixedDestination(
      destination: destination,
      writer: const FileSelectorAdapter(),
    ),
    clock: const SystemClock(),
  );

  test('写出目标文件、内容完整，且不留下暂存文件', () async {
    final destination = '${workspace.path}${Platform.pathSeparator}out.json';

    final result = await serviceWritingTo(destination).exportJson();

    expect(result.status, ExportStatus.completed);
    expect(result.recordCount, 1);
    final written = File(destination);
    expect(written.existsSync(), isTrue);
    final text = written.readAsStringSync();
    expect(text, contains('"schemaVersion":1'));
    expect(text, contains('"写方案"'));

    // 暂存文件必须被清掉：留在用户目录里等于把中间产物丢给用户。
    final leftovers = workspace
        .listSync()
        .map((entity) => entity.path)
        .where((path) => path.endsWith('.partial'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('目标文件已存在时能覆盖（另存为允许确认覆盖）', () async {
    final destination = '${workspace.path}${Platform.pathSeparator}out.json';
    File(destination).writeAsStringSync('旧内容');

    final result = await serviceWritingTo(destination).exportJson();

    expect(result.status, ExportStatus.completed);
    expect(File(destination).readAsStringSync(), isNot(contains('旧内容')));
    expect(File(destination).readAsStringSync(), contains('"schemaVersion":1'));
  });

  test('CSV 同样写得出', () async {
    final destination = '${workspace.path}${Platform.pathSeparator}out.csv';

    final result = await serviceWritingTo(destination).exportCsv();

    expect(result.status, ExportStatus.completed);
    // BOM 必须按字节看：`readAsStringSync` 会把开头的 BOM 吃掉，用字符串断言
    // 反而永远失败（Excel 需要这三个字节才认 UTF-8）。
    final bytes = File(destination).readAsBytesSync();
    expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
    final text = File(destination).readAsStringSync();
    expect(text, contains('dataset,record_id'));
    expect(text, contains('写方案'));
  });

  test('暂存文件在目标旁边，不在系统临时目录', () async {
    // 这条断言直接钉住**暂存位置**，因此与运行环境的 %TEMP% 是否可写无关：
    // 旧实现把暂存文件放在 `Directory.systemTemp` 下，于是"是否可写"决定了导出成不成，
    // 而用户选的目标位置根本没参与。写入过程中检查目标旁边的 `.partial` 是否存在，
    // 就能在临时目录可写的机器上照样抓住这次回归。
    final destination = '${workspace.path}${Platform.pathSeparator}probe.json';
    final stagingBesideTarget = <bool>[];

    final stream = () async* {
      yield [0x61];
      stagingBesideTarget.add(File('$destination.partial').existsSync());
      yield [0x62];
    }();

    final path = await const FileSelectorAdapter().writeFile(
      destination: destination,
      bytes: stream,
    );

    expect(path, destination);
    expect(stagingBesideTarget, [
      isTrue,
    ], reason: '暂存文件应当出现在目标旁边；为 false 说明它被放到了别处（例如 %TEMP%）');
    expect(File(destination).readAsStringSync(), 'ab');
  });

  test('另存为对话框从"本应用写得进去"的目录开始', () async {
    // 受限机器上对话框默认落在桌面时，用户怎么选都会被系统拒绝；起始目录因此是
    // 功能的一部分，而不是外观细节。这里只验证适配器把它交给了平台。
    final dialog = _RecordingSaveDialog();
    final previous = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = dialog;
    addTearDown(() => FileSelectorPlatform.instance = previous);

    const writable = r'G:\best-planing\release\build\user-data';
    final path = await const FileSelectorAdapter(
      initialDirectory: writable,
    ).chooseSaveLocation(suggestedName: 'planner-export.csv', extension: 'csv');

    expect(dialog.initialDirectory, writable);
    expect(dialog.suggestedName, 'planner-export.csv');
    expect(path, r'G:\somewhere\out.json');
  });

  test('未指定起始目录时不传（交给系统默认）', () async {
    final dialog = _RecordingSaveDialog();
    final previous = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = dialog;
    addTearDown(() => FileSelectorPlatform.instance = previous);

    await const FileSelectorAdapter().chooseSaveLocation(
      suggestedName: 'planner-export.json',
      extension: 'json',
    );

    expect(dialog.initialDirectory, isNull);
  });
}
