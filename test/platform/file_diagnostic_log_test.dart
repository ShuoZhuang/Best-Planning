// 诊断日志的三条不变量。**它们都不是"锦上添花"**：
//
// 加这个日志的原因是一件具体的事——Release 构建里此前没有任何可查的线索（`debugPrint` 在打包后
// 的 Windows 应用里抓不到，实测过），于是"提醒同步失败"既不产生提醒、也不留痕迹。因此：
//   ① 它必须**真的写出内容**（否则等于没有）；
//   ② 它**绝不能抛异常**——为了可观测而制造一个新的失败点是本末倒置；
//   ③ 它必须有上限（长期运行不该把磁盘写满）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/platform/diagnostics/file_diagnostic_log.dart';

void main() {
  late Directory temp;
  late String logPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('diag-log-test');
    logPath = '${temp.path}${Platform.pathSeparator}diagnostics.log';
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('写下带时间戳的行，且是追加而不是覆盖', () {
    final log = FileDiagnosticLog(
      logPath,
      now: () => DateTime.utc(2026, 10, 4, 0, 30),
    );

    log.write('第一行');
    log.write('第二行');

    final content = File(logPath).readAsStringSync();
    expect(content, contains('2026-10-04T00:30:00.000Z'));
    expect(content.indexOf('第一行'), lessThan(content.indexOf('第二行')));
    expect(log.failed, isFalse);
  });

  test('写失败不抛异常，只置 failed —— 诊断不得成为新的失败点', () {
    // 用一个**必然是目录**的路径：往目录上追加文件会失败。
    final asDirectory = '${temp.path}${Platform.pathSeparator}iam-a-dir';
    Directory(asDirectory).createSync();
    final log = FileDiagnosticLog(asDirectory);

    // 关键断言：这一句不许抛。
    expect(() => log.write('写不进去'), returnsNormally);
    expect(log.failed, isTrue, reason: '失败了就要能被上层查到，不能静默消失');
  });

  test('超过上限时截断较早内容，而不是无限增长', () {
    final log = FileDiagnosticLog(logPath, maxBytes: 200);
    for (var index = 0; index < 50; index++) {
      log.write('第 $index 行：${'x' * 20}');
    }

    final size = File(logPath).lengthSync();
    // 截断发生在"写之前"，因此最终大小是"上限 + 一行"，不会是 50 行的总量。
    expect(size, lessThan(200 + 200));
    expect(File(logPath).readAsStringSync(), contains('已截断较早内容'));
  });
}
