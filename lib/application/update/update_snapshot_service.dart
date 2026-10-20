// 更新前的数据快照（规格 §13.1 / UPD-035）。
//
// 快照由主程序生成，包含数据库、设置、更新状态与数据格式版本；助手只把它当作**不透明文件**
// 按清单恢复，不解析业务内容（规格 §12.4）。
//
// 顺序很重要：先让数据库完成检查点（WAL 落盘），再复制文件，最后写清单。清单里的
// SHA-256 让"恢复了一半的快照"无法被当成完整快照使用。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

/// 一个需要进入快照的文件。
final class SnapshotSource {
  const SnapshotSource({required this.file, required this.relativePath});

  final File file;

  /// 相对数据目录的路径。**不允许绝对路径或 `..`**。
  final String relativePath;
}

final class UpdateSnapshotResult {
  const UpdateSnapshotResult({
    required this.directoryPath,
    required this.manifestPath,
    required this.sha256,
    required this.files,
  });

  final String directoryPath;
  final String manifestPath;
  final String sha256;
  final int files;

  Map<String, Object?> toJson() => {
    'directoryPath': directoryPath,
    'manifestPath': manifestPath,
    'sha256': sha256,
    'files': files,
  };
}

final class UpdateSnapshotService {
  UpdateSnapshotService({
    required this.layout,
    required this.sources,
    required this.clock,
    this.checkpoint,
  });

  final UpdateStorageLayout layout;
  final List<SnapshotSource> sources;
  final Clock clock;

  /// 数据库检查点/一致性检查。为 `null` 时调用方必须已经冻结写入。
  final Future<void> Function()? checkpoint;

  Future<UpdateSnapshotResult> create({required String transactionId}) async {
    final checkpointCallback = checkpoint;
    if (checkpointCallback != null) await checkpointCallback();

    final directory = Directory(
      '${layout.root.path}${Platform.pathSeparator}snapshot-$transactionId',
    );
    await directory.create(recursive: true);

    final files = <Map<String, Object?>>[];
    for (final source in sources) {
      final relative = _sanitizeRelative(source.relativePath);
      if (relative == null) {
        throw StateError('非法的快照相对路径：${source.relativePath}');
      }
      if (!await source.file.exists()) continue;
      final target = File(
        '${directory.path}${Platform.pathSeparator}$relative',
      );
      await target.parent.create(recursive: true);
      final bytes = await source.file.readAsBytes();
      await target.writeAsBytes(bytes, flush: true);
      files.add({
        'relative': relative,
        'sha256': sha256.convert(bytes).toString(),
        'sizeBytes': bytes.length,
      });
    }

    final manifest = {
      'schemaVersion': 1,
      'transactionId': transactionId,
      'createdAtUtc': clock.nowUtc().toIso8601String(),
      'files': files,
    };
    final manifestJson = jsonEncode(manifest);
    final manifestFile = File(
      '${directory.path}${Platform.pathSeparator}snapshot-manifest.json',
    );
    await manifestFile.writeAsString(manifestJson, flush: true);

    return UpdateSnapshotResult(
      directoryPath: directory.path,
      manifestPath: manifestFile.path,
      sha256: sha256.convert(utf8.encode(manifestJson)).toString(),
      files: files.length,
    );
  }

  /// 相对路径只允许普通目录段；`..`、盘符与绝对路径一律拒绝。
  static String? _sanitizeRelative(String value) {
    final normalized = value.replaceAll('\\', '/');
    if (normalized.isEmpty || normalized.startsWith('/')) return null;
    if (RegExp(r'^[A-Za-z]:').hasMatch(normalized)) return null;
    final parts = normalized.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      return null;
    }
    return parts.join(Platform.pathSeparator);
  }
}
