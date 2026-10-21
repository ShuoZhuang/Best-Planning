// 正常更新流程无弹窗/通知/浏览器跳转（规格 §11.3 / UPD-026）。
//
// 这是一条静态门禁：更新相关的界面与编排代码里不得出现 `showDialog`、底部弹层、
// `ScaffoldMessenger`、系统通知插件或直接打开浏览器。唯一的例外是设置页的
// "查看更新说明"——它通过注入的 `openUrl` 回调交给路由层，不在更新组件内部调用。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _scannedDirectories = [
  'lib/features/shell',
  'lib/features/settings/update',
  'lib/application/update',
];

const _forbidden = {
  'showDialog(': '对话框',
  'showGeneralDialog(': '通用对话框',
  'showModalBottomSheet(': '底部弹层',
  'ScaffoldMessenger': 'SnackBar/提示条',
  'FlutterLocalNotificationsPlugin': '系统通知',
  'NotificationService': '系统通知服务',
  'launchUrl(': '直接打开浏览器',
  'url_launcher': '浏览器依赖',
};

String _stripLineComments(String source) => source
    .split('\n')
    .map((line) {
      final index = line.indexOf('//');
      return index < 0 ? line : line.substring(0, index);
    })
    .join('\n');

void main() {
  test('更新相关代码不弹窗、不发通知、不直接打开浏览器（UPD-026）', () {
    final files = <File>[];
    for (final directory in _scannedDirectories) {
      final root = Directory(directory);
      if (!root.existsSync()) continue;
      files.addAll(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart')),
      );
    }

    expect(
      files.length,
      greaterThan(8),
      reason: '只扫到 ${files.length} 个文件，扫描路径可能失效',
    );

    final hits = <String>[];
    for (final file in files) {
      final code = _stripLineComments(file.readAsStringSync());
      for (final entry in _forbidden.entries) {
        if (code.contains(entry.key)) {
          hits.add('${file.path} 含 ${entry.key}（${entry.value}）');
        }
      }
    }

    expect(hits, isEmpty, reason: '正常更新流程不允许弹窗/通知/浏览器跳转：$hits');
  });
}
