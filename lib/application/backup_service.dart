import 'dart:convert';
import 'dart:io';

import 'package:personal_planner/core/clock.dart';

final class DatabaseInspection {
  const DatabaseInspection({
    required this.schemaVersion,
    required this.integrityOk,
  });

  final int schemaVersion;
  final bool integrityOk;
}

abstract interface class DatabaseLifecyclePort {
  int get supportedSchemaVersion;

  Future<void> createConsistentSnapshot(String destination);

  Future<DatabaseInspection> inspect(String candidate);

  Future<void> replaceWith(String validatedDatabase);

  Future<void> eraseAll();
}

abstract interface class BackupHashPort {
  Future<String> sha256File(String path);
}

abstract interface class BackupArchivePort {
  Future<void> createArchive({
    required String destination,
    required String manifestJson,
    required String databasePath,
    required String settingsJson,
  });

  Future<StagedBackup> stageArchive(String source);
}

abstract interface class BackupIndexPort {
  Future<void> clear();
}

final class StagedBackup {
  const StagedBackup({
    required this.root,
    required this.manifestPath,
    required this.databasePath,
    required this.settingsPath,
  });

  final String root;
  final String manifestPath;
  final String databasePath;
  final String settingsPath;

  Future<void> cleanup() async {
    final directory = Directory(root);
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

final class BackupManifest {
  const BackupManifest({
    required this.formatVersion,
    required this.schemaVersion,
    required this.appVersion,
    required this.createdAtUtc,
    required this.databaseLength,
    required this.sha256,
  });

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    try {
      return BackupManifest(
        formatVersion: json['formatVersion'] as int,
        schemaVersion: json['schemaVersion'] as int,
        appVersion: json['appVersion'] as String,
        createdAtUtc: DateTime.parse(json['createdAtUtc'] as String).toUtc(),
        databaseLength: json['databaseLength'] as int,
        sha256: json['sha256'] as String,
      );
    } catch (_) {
      throw const BackupValidationException('invalidManifest');
    }
  }

  final int formatVersion;
  final int schemaVersion;
  final String appVersion;
  final DateTime createdAtUtc;
  final int databaseLength;
  final String sha256;

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'schemaVersion': schemaVersion,
    'appVersion': appVersion,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'databaseLength': databaseLength,
    'sha256': sha256,
  };
}

final class BackupValidationException implements Exception {
  const BackupValidationException(this.code);
  final String code;

  @override
  String toString() => 'BackupValidationException($code)';
}

final class BackupService {
  const BackupService({
    required this.database,
    required this.archives,
    required this.hashes,
    required this.clock,
    required this.appVersion,
    required this.settingsJson,
  });

  static const formatVersion = 1;

  final DatabaseLifecyclePort database;
  final BackupArchivePort archives;
  final BackupHashPort hashes;
  final Clock clock;
  final String appVersion;
  final Future<String> Function() settingsJson;

  Future<BackupManifest> create(String destination) async {
    final parent = File(destination).parent;
    await parent.create(recursive: true);
    final temporary = await parent.createTemp('planner-backup-create-');
    try {
      final snapshot =
          '${temporary.path}${Platform.pathSeparator}planner.sqlite';
      await database.createConsistentSnapshot(snapshot);
      final inspection = await database.inspect(snapshot);
      if (!inspection.integrityOk) {
        throw const BackupValidationException('sourceIntegrity');
      }
      final file = File(snapshot);
      final manifest = BackupManifest(
        formatVersion: formatVersion,
        schemaVersion: inspection.schemaVersion,
        appVersion: appVersion,
        createdAtUtc: clock.nowUtc(),
        databaseLength: await file.length(),
        sha256: await hashes.sha256File(snapshot),
      );
      await archives.createArchive(
        destination: destination,
        manifestJson: jsonEncode(manifest.toJson()),
        databasePath: snapshot,
        settingsJson: await settingsJson(),
      );
      return manifest;
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  }

  Future<BackupManifest> validate(String source) async {
    final staged = await _stageAndValidate(source);
    try {
      return staged.$2;
    } finally {
      await staged.$1.cleanup();
    }
  }

  Future<BackupManifest> restore(String source) async {
    final staged = await _stageAndValidate(source);
    try {
      await database.replaceWith(staged.$1.databasePath);
      return staged.$2;
    } finally {
      await staged.$1.cleanup();
    }
  }

  Future<(StagedBackup, BackupManifest)> _stageAndValidate(
    String source,
  ) async {
    StagedBackup? staged;
    try {
      staged = await archives.stageArchive(source);
      final manifestRaw = jsonDecode(
        await File(staged.manifestPath).readAsString(),
      );
      if (manifestRaw is! Map<String, Object?>) {
        throw const BackupValidationException('invalidManifest');
      }
      final manifest = BackupManifest.fromJson(manifestRaw);
      if (manifest.formatVersion != formatVersion) {
        throw const BackupValidationException('unsupportedFormat');
      }
      if (manifest.schemaVersion > database.supportedSchemaVersion) {
        throw const BackupValidationException('newerSchema');
      }
      final file = File(staged.databasePath);
      if (await file.length() != manifest.databaseLength) {
        throw const BackupValidationException('lengthMismatch');
      }
      if (await hashes.sha256File(staged.databasePath) != manifest.sha256) {
        throw const BackupValidationException('hashMismatch');
      }
      final inspection = await database.inspect(staged.databasePath);
      if (!inspection.integrityOk) {
        throw const BackupValidationException('integrityCheck');
      }
      if (inspection.schemaVersion != manifest.schemaVersion) {
        throw const BackupValidationException('schemaMismatch');
      }
      return (staged, manifest);
    } on BackupValidationException {
      if (staged != null) await staged.cleanup();
      rethrow;
    } catch (_) {
      if (staged != null) await staged.cleanup();
      throw const BackupValidationException('invalidArchive');
    }
  }
}
