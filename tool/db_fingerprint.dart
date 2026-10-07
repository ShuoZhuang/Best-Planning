// 只读探针：打印一个 SQLite 库里的表名与行数，用来证明"覆盖安装前后本地数据没有变化"。
//
// 为什么要有它：安装台账此前只能写"数据库文件大小与修改时间一致"，而那两样都不足以说明
// **内容**没变（同一个大小可能是不同的内容；任何一次启动都可能重写 mtime）。这个探针给出
// 可逐项对比的内容指纹，且**只读**打开——不会影响正在使用的库。
//
// 用法：dart run tool/db_fingerprint.dart <sqlite 路径>
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/db_fingerprint.dart <sqlite 路径>');
    exit(2);
  }
  final path = args.first;
  if (!File(path).existsSync()) {
    stderr.writeln('找不到数据库：$path');
    exit(2);
  }

  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    final tables = db
        .select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%' ORDER BY name",
        )
        .map((row) => row['name'] as String)
        .toList();

    var total = 0;
    for (final table in tables) {
      final count =
          db.select('SELECT COUNT(*) AS n FROM "$table"').first['n'] as int;
      total += count;
      stdout.writeln('$table=$count');
    }
    stdout.writeln('TABLES=${tables.length} TOTAL_ROWS=$total');
  } finally {
    db.close();
  }
}
