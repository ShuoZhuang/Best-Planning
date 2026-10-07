// 一次性工具：清除"新手教程已看过"的标记，让下次启动重新提示。
//
// **为什么需要它**：2026-10-07 的自动化截图过程中，程序化点击把教程"跳过"了（那次交互不是用户
// 本人做的），于是 `onboarding.tutorialSeen.v1` 被写进了真实库，用户再也看不到首次教程。
// 这个脚本把那一行删掉，恢复"第一次使用会看到教程"的状态。
//
// 与 `db_fingerprint.dart` 的只读约定**故意不同**：这里要写。因此只删这一个键，不碰任何其它行，
// 并且打印删了多少行以便核对。
//
// 用法：dart run tool/reset_tutorial_seen.dart <sqlite 路径>
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/reset_tutorial_seen.dart <sqlite 路径>');
    exit(2);
  }
  final path = args.first;
  if (!File(path).existsSync()) {
    stderr.writeln('找不到数据库：$path');
    exit(2);
  }

  // 显式指定读写模式：默认模式在这个驱动版本下以只读打开，DELETE 直接报 SQLITE_READONLY
  // （实测：文件 ACL 与目录都可写，唯独语句执行失败）。写工具的打开模式不该靠默认值。
  final db = sqlite3.open(path, mode: OpenMode.readWrite);
  try {
    db.execute("DELETE FROM settings WHERE key = 'onboarding.tutorialSeen.v1'");
    final left =
        db
                .select(
                  "SELECT COUNT(*) AS n FROM settings WHERE key = 'onboarding.tutorialSeen.v1'",
                )
                .first['n']
            as int;
    stdout.writeln('剩余 tutorialSeen 行数=$left（0 表示已清除）');
  } finally {
    db.close();
  }
}
