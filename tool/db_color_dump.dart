// 只读探针：把数据库里"日程分类颜色"的实际取值打出来。
//
// 为什么需要它：排障时"用户看到的是哪种颜色"只能从数据里读，不能从代码默认值推断——默认色
// 只在用户从未改过时生效，而设置里的 `schedule.colors.v1` 一旦存在就覆盖默认。此前对比截图
// 时就因为没先读这一行而多绕了一圈。
//
// 用法：dart run tool/db_color_dump.dart <sqlite 路径>
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

String hex(int argb) =>
    '#${(argb & 0xffffffff).toRadixString(16).padLeft(8, '0').toUpperCase()}';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/db_color_dump.dart <sqlite 路径>');
    exit(2);
  }
  final db = sqlite3.open(args.first, mode: OpenMode.readOnly);
  try {
    stdout.writeln('== settings ==');
    for (final row in db.select(
      "SELECT key, json_value FROM settings ORDER BY key",
    )) {
      final key = row['key'] as String;
      if (key.contains('color') || key.contains('appearance')) {
        stdout.writeln('$key = ${row['json_value']}');
      }
    }
    stdout.writeln('== areas ==');
    for (final row in db.select(
      'SELECT name, sort_order, color FROM areas ORDER BY sort_order',
    )) {
      stdout.writeln(
        '${row['name']}  sort=${row['sort_order']}  color=${hex(row['color'] as int)}',
      );
    }
  } finally {
    db.close();
  }
}
