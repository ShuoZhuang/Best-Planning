import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:personal_planner/application/export_service.dart';

final class FileSelectorAdapter implements ExportFilePort {
  const FileSelectorAdapter();

  @override
  Future<String?> chooseDirectory() => getDirectoryPath();

  Future<String?> chooseBackupDestination() async {
    final location = await getSaveLocation(
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
  Future<String> writeNewFile({
    required String directory,
    required String preferredName,
    required Stream<List<int>> bytes,
  }) async {
    final parent = Directory(directory);
    if (!await parent.exists()) {
      throw FileSystemException('导出目录不存在', directory);
    }
    final destination = await _availableFile(parent, preferredName);
    final temporary = File(
      '${destination.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    IOSink? sink;
    try {
      sink = temporary.openWrite(mode: FileMode.writeOnly);
      await sink.addStream(bytes);
      await sink.flush();
      await sink.close();
      sink = null;
      await temporary.rename(destination.path);
      return destination.path;
    } catch (_) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // Preserve the original write error.
        }
      }
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  static Future<File> _availableFile(
    Directory parent,
    String preferredName,
  ) async {
    final separator = Platform.pathSeparator;
    final dot = preferredName.lastIndexOf('.');
    final stem = dot > 0 ? preferredName.substring(0, dot) : preferredName;
    final extension = dot > 0 ? preferredName.substring(dot) : '';
    var candidate = File('${parent.path}$separator$preferredName');
    var suffix = 2;
    while (await candidate.exists()) {
      candidate = File('${parent.path}$separator$stem ($suffix)$extension');
      suffix++;
    }
    return candidate;
  }
}
