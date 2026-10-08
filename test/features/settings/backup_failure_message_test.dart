// M9（路线图 §13 第 3 条）："拒绝访问路径能**恢复**选择"。
//
// 这一条在**导出**那半边的恢复路径已经有人守（`export_page_test.dart`）。
// 本文件守**备份**这半边，并且守的是一处**真实缺陷**：
//
// `backup_page.dart` 的兜底分支原来是 `'操作失败：$error'` —— 把异常**原样**打到界面上。
// `BackupService` 自己抛的是结构化的 `BackupValidationException`（只有 `code`，安全），
// 但兜底分支接的是**任意**异常：文件被占用、磁盘满、路径无权限会以
// `FileSystemException` / `PathAccessException` 冒出来，而 Dart 这些异常的 `toString()`
// **带着完整路径**。于是「拒绝访问」那一步会把用户的目录结构摆到屏幕上。
//
// 为什么用纯函数测而不是驱动整个页面：`BackupPage` 要的是**具体**的
// `BackupService` + `FileSelectorAdapter` + 真实数据库端口，为了造一个"写入被拒"的场景
// 去搭那一整套替身，测到的多半是替身自己的行为。而这段逻辑是纯的——
// 输入一段异常文本，输出给用户看的那句话——**直接测它更准，也更稳**。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/features/settings/data/backup_page.dart';

void main() {
  test('M9 备份失败的消息不暴露本机路径（带引号的 path = ... 形式）', () {
    // Dart 的 `FileSystemException` 真实长相。
    final message = backupFailureMessage(
      const _FakeError(
        "FileSystemException: Cannot open file, "
        "path = 'F:\\Documents\\personal_planner.sqlite' "
        "(OS Error: 拒绝访问。, errno = 5)",
      ),
    );

    expect(message, isNot(contains(r'F:\Documents')));
    expect(message, isNot(contains('personal_planner.sqlite')));
    expect(message, isNot(contains('Documents')));
    // **但有用的信息要留下**：用户得知道是"拒绝访问"，否则他只会反复点。
    expect(message, contains('拒绝访问'));
    // 也不能剩下孤零零的引号。
    expect(message, isNot(contains("''")));
  });

  test('M9 备份失败的消息不暴露 UNC 路径', () {
    final message = backupFailureMessage(
      const _FakeError(
        r'FileSystemException: Cannot create file, '
        r"path = '\\nas\share\backups\planner.zip' (OS Error: 网络名不再可用。, errno = 64)",
      ),
    );
    expect(message, isNot(contains(r'\\nas')));
    expect(message, isNot(contains('share')));
    expect(message, contains('网络名不再可用'));
  });

  test('M9 没有路径的异常原文照常保留（不为了脱敏把信息全丢掉）', () {
    final message = backupFailureMessage(const _FakeError('磁盘空间不足'));
    expect(message, contains('磁盘空间不足'));
    expect(message, startsWith('操作失败：'));
  });

  test('M9 消息里出现多个路径时全部被替换', () {
    final message = backupFailureMessage(
      const _FakeError(
        r"copy from 'C:\a\planner.sqlite' to 'D:\b\planner.zip' failed",
      ),
    );
    expect(message, isNot(contains(r'C:\a')));
    expect(message, isNot(contains(r'D:\b')));
    expect(message, isNot(contains('planner.sqlite')));
    expect(message, contains('failed'));
  });

  test('M9 短路径片段（盘符根）也不会漏出去', () {
    final message = backupFailureMessage(const _FakeError(r'denied at F:\'));
    expect(message, isNot(contains(r'F:\')));
  });
}

/// 一个 `toString()` 可控的假异常，用来喂 `backupFailureMessage`。
final class _FakeError implements Exception {
  const _FakeError(this.text);
  final String text;
  @override
  String toString() => text;
}
