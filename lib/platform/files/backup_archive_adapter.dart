import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:personal_planner/application/backup_service.dart';

final class BackupArchiveAdapter implements BackupArchivePort {
  const BackupArchiveAdapter();

  static const _expectedFiles = {
    'manifest.json',
    'planner.sqlite',
    'exports/settings.json',
  };
  static const _maximumArchiveBytes = 128 * 1024 * 1024;

  @override
  Future<void> createArchive({
    required String destination,
    required String manifestJson,
    required String databasePath,
    required String settingsJson,
  }) async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('manifest.json', manifestJson))
      ..addFile(
        ArchiveFile.bytes(
          'planner.sqlite',
          await File(databasePath).readAsBytes(),
        ),
      )
      ..addFile(ArchiveFile.string('exports/settings.json', settingsJson));
    final output = File(destination);
    final temporary = File(
      '${output.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    final previous = File('${output.path}.previous-$pid');
    try {
      await temporary.writeAsBytes(
        ZipEncoder().encodeBytes(archive),
        flush: true,
      );
      if (await previous.exists()) await previous.delete();
      if (await output.exists()) await output.rename(previous.path);
      try {
        await temporary.rename(output.path);
        if (await previous.exists()) await previous.delete();
      } catch (_) {
        if (await previous.exists()) await previous.rename(output.path);
        rethrow;
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
      if (await previous.exists() && !await output.exists()) {
        await previous.rename(output.path);
      }
    }
  }

  @override
  Future<StagedBackup> stageArchive(String source) async {
    final sourceFile = File(source);
    final root = await sourceFile.parent.createTemp('planner-restore-');
    try {
      if (await sourceFile.length() > _maximumArchiveBytes) {
        throw const BackupValidationException('archiveTooLarge');
      }
      final archive = ZipDecoder().decodeBytes(await sourceFile.readAsBytes());
      final seen = <String>{};
      for (final entry in archive) {
        final name = entry.name.replaceAll('\\', '/');
        if (!_isSafeExpectedPath(name) || !entry.isFile || !seen.add(name)) {
          throw const BackupValidationException('unsafeArchivePath');
        }
        if (entry.size > _maximumArchiveBytes) {
          throw const BackupValidationException('archiveEntryTooLarge');
        }
        final bytes = entry.readBytes();
        if (bytes == null) {
          throw const BackupValidationException('invalidArchiveEntry');
        }
        final target = File(
          '${root.path}${Platform.pathSeparator}'
          '${name.replaceAll('/', Platform.pathSeparator)}',
        );
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes, flush: true);
      }
      if (!seen.containsAll(_expectedFiles) ||
          seen.length != _expectedFiles.length) {
        throw const BackupValidationException('missingArchiveEntry');
      }
      return StagedBackup(
        root: root.path,
        manifestPath: '${root.path}${Platform.pathSeparator}manifest.json',
        databasePath: '${root.path}${Platform.pathSeparator}planner.sqlite',
        settingsPath:
            '${root.path}${Platform.pathSeparator}exports'
            '${Platform.pathSeparator}settings.json',
      );
    } catch (_) {
      if (await root.exists()) await root.delete(recursive: true);
      rethrow;
    }
  }

  static bool _isSafeExpectedPath(String name) {
    if (name.startsWith('/') || name.contains(':')) return false;
    final parts = name.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      return false;
    }
    return _expectedFiles.contains(name);
  }
}

final class Sha256FileHashAdapter implements BackupHashPort {
  const Sha256FileHashAdapter();

  @override
  Future<String> sha256File(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();
}
