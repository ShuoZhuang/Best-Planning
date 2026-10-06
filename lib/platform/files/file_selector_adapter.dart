import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:personal_planner/application/export_service.dart';

final class FileSelectorAdapter implements ExportFilePort {
  const FileSelectorAdapter({this.initialDirectory});

  /// 另存为对话框的起始目录。
  ///
  /// 应当传一个**本应用确实写得进去**的目录。受限环境里这条不是锦上添花：当进程处于低
  /// 完整性级别时，Windows 禁止它写用户桌面／文档／临时目录，对话框默认落在桌面上会让
  /// 用户无论怎么选都被系统拒绝（"你没有权限在此位置中保存文件"），而起始目录至少是他
  /// 能成功保存的地方。
  final String? initialDirectory;

  @override
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required String extension,
  }) async {
    final location = await getSaveLocation(
      initialDirectory: initialDirectory,
      suggestedName: suggestedName,
      acceptedTypeGroups: [
        XTypeGroup(
          label: extension == 'json' ? 'JSON 数据' : 'CSV 表格',
          extensions: [extension],
        ),
      ],
    );
    return location?.path;
  }

  Future<String?> chooseBackupDestination() async {
    final location = await getSaveLocation(
      initialDirectory: initialDirectory,
      suggestedName: 'planner-backup.zip',
      acceptedTypeGroups: const [
        XTypeGroup(label: '智能日程备份', extensions: ['zip']),
      ],
    );
    return location?.path;
  }

  Future<String?> chooseBackupSource() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '智能日程备份', extensions: ['zip']),
      ],
    );
    return file?.path;
  }

  @override
  Future<String> writeFile({
    required String destination,
    required Stream<List<int>> bytes,
  }) async {
    final target = File(destination);
    // 暂存文件放在**目标旁边**，不要用 `Directory.systemTemp`。
    //
    // 曾经用 `%TEMP%` 暂存：在用户临时目录被锁住的机器上（本项目所在机器就是——
    // Dart 在 `C:\Users\<user>\AppData\Local\Temp` 下建文件返回 errno 5，而工作区内正常），
    // 暂存这一步**先于**目标路径失败，于是用户换到任何一个位置都只看到"没有权限"，
    // 而真正被拒绝的其实是从未参与选择的临时目录。失败的步骤与用户的选择无关时，
    // 提示必须指向用户真正选的那个位置。
    final staging = File('${target.path}.partial');
    IOSink? sink;
    try {
      sink = staging.openWrite(mode: FileMode.writeOnly);
      await sink.addStream(bytes);
      await sink.flush();
      await sink.close();
      sink = null;
      // `copy` 而不是 `rename`：Windows 上 rename 到已存在的文件会失败，而另存为
      // 对话框允许用户确认覆盖一个已有文件。
      await staging.copy(target.path);
      return target.path;
    } on FileSystemException {
      throw const ExportWriteException();
    } catch (_) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // Preserve the original write error.
        }
      }
      rethrow;
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // Cleanup must not replace the original export error.
        }
      }
      if (await staging.exists()) {
        try {
          await staging.delete();
        } catch (_) {
          // The export result is more important than staging cleanup failure.
        }
      }
    }
  }
}
