import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:personal_planner/application/export_service.dart';

final class FileSelectorAdapter implements ExportFilePort {
  const FileSelectorAdapter();

  @override
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required String extension,
  }) async {
    final location = await getSaveLocation(
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
    final staging = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'planner-export-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    IOSink? sink;
    try {
      sink = staging.openWrite(mode: FileMode.writeOnly);
      await sink.addStream(bytes);
      await sink.flush();
      await sink.close();
      sink = null;
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
