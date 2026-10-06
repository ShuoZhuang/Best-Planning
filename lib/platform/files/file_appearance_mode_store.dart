import 'dart:io';

import 'package:personal_planner/application/appearance_service.dart';

String appearanceModePathIn(String supportDirectory) =>
    '$supportDirectory${Platform.pathSeparator}personal_planner.appearance-mode';

String? packagedAppearanceSupportDirectory({
  required String? localAppData,
  required String? applicationUserModelId,
}) {
  if (localAppData == null || localAppData.trim().isEmpty) return null;
  if (applicationUserModelId == null) return null;
  final separator = applicationUserModelId.indexOf('!');
  if (separator <= 0) return null;
  final packageFamilyName = applicationUserModelId.substring(0, separator);
  return '${localAppData.trim()}${Platform.pathSeparator}Packages'
      '${Platform.pathSeparator}$packageFamilyName'
      '${Platform.pathSeparator}LocalState';
}

Future<Directory> resolveWritableAppearanceDirectory(
  Iterable<Directory> candidates,
) async {
  Object? lastError;
  StackTrace? lastStackTrace;
  for (final directory in candidates) {
    final probe = File(
      '${directory.path}${Platform.pathSeparator}.appearance-write-probe',
    );
    try {
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      await probe.writeAsString('probe', flush: true);
      await probe.delete();
      return directory;
    } catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
      try {
        if (await probe.exists()) await probe.delete();
      } on Object {
        // The candidate is already rejected; cleanup failure changes nothing.
      }
    }
  }
  if (lastError != null && lastStackTrace != null) {
    Error.throwWithStackTrace(lastError, lastStackTrace);
  }
  throw StateError('No appearance storage directory candidates were provided');
}

final class FileAppearanceModeStore implements AppearanceModeStore {
  FileAppearanceModeStore(String path) : _file = File(path);

  final File _file;

  @override
  Future<String?> read() async {
    if (!await _file.exists()) return null;
    final value = (await _file.readAsString()).trim();
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String value) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(value, flush: true);
  }
}
